import Foundation
import os

/// Serves a BlockBackend to the guest kernel's NBD client. The guest configures
/// the device with ioctls, so only the transmission phase is spoken here
/// (big-endian simple replies).
///
/// Requests are read on one thread and executed, in order, on another. Reading
/// must never wait for a reply to be sent: vsock carries both directions over
/// one credit-controlled link, so if the host stops reading while a large reply
/// is blocked, the guest can't send the credit update that would unblock it, and
/// both sides wait forever.
final class NBDServer: @unchecked Sendable {
    private enum Command: UInt16 {
        case read = 0, write = 1, disconnect = 2, flush = 3, trim = 4
    }

    private struct Request {
        let command: Command
        let handle: [UInt8]
        let offset: UInt64
        let length: Int
        let payload: UnsafeMutableRawBufferPointer?
    }

    private static let requestMagic: UInt32 = 0x2560_9513
    private static let replyMagic: UInt32 = 0x6744_6698
    private static let maxRequest = 32 << 20

    private let fd: Int32
    private let backend: BlockBackend
    private let keepAlive: AnyObject
    private let log = Logger(subsystem: "ntfsbridge", category: "nbd")
    private(set) var counts = (reads: 0, writes: 0, flushes: 0, errors: 0)

    private let lock = NSCondition()
    private var queue: [Request] = []
    private var closed = false

    init(fd: Int32, backend: BlockBackend, keepAlive: AnyObject) {
        self.fd = fd
        self.backend = backend
        self.keepAlive = keepAlive
    }

    func start() {
        let reader = Thread { [self] in receive() }
        reader.name = "ntfsbridge.nbd.recv"
        reader.qualityOfService = .userInitiated
        let worker = Thread { [self] in execute() }
        worker.name = "ntfsbridge.nbd"
        worker.qualityOfService = .userInitiated
        worker.start()
        reader.start()
    }

    /// Reads requests (and write payloads) as fast as the guest sends them.
    private func receive() {
        defer { enqueue(nil) }
        var header = [UInt8](repeating: 0, count: 28)
        while readExactly(&header) {
            let magic = be32(header, 0)
            let type = be16(header, 6)
            let length = Int(be32(header, 24))
            guard magic == Self.requestMagic, length <= Self.maxRequest,
                  let command = Command(rawValue: type & 0x00ff) else {
                log.error("bad NBD request magic=\(magic) type=\(type) len=\(length)")
                return
            }
            var payload: UnsafeMutableRawBufferPointer?
            if command == .write {
                let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: max(length, 1), alignment: 4096)
                guard readExactly(UnsafeMutableRawBufferPointer(rebasing: buf[0..<length])) else {
                    buf.deallocate()
                    return
                }
                payload = buf
            }
            enqueue(Request(command: command, handle: Array(header[8..<16]),
                            offset: be64(header, 16), length: length, payload: payload))
            if command == .disconnect { return }
        }
    }

    /// `nil` marks the end of the stream.
    private func enqueue(_ request: Request?) {
        lock.lock()
        if let request { queue.append(request) } else { closed = true }
        lock.signal()
        lock.unlock()
    }

    private func dequeue() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        while queue.isEmpty && !closed { lock.wait() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    /// Executes requests in arrival order and sends each reply.
    private func execute() {
        var buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 4096)
        defer {
            buffer.deallocate()
            while let left = dequeue() { left.payload?.deallocate() }
        }
        while let request = dequeue() {
            defer { request.payload?.deallocate() }
            var status: Int32 = 0
            var data: UnsafeRawBufferPointer?
            switch request.command {
            case .read:
                counts.reads += 1
                if request.length > buffer.count {
                    buffer.deallocate()
                    buffer = .allocate(byteCount: request.length, alignment: 4096)
                }
                let span = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<request.length])
                do { try backend.read(into: span, at: request.offset) } catch { status = fail(error, "read") }
                if status == 0 { data = UnsafeRawBufferPointer(span) }
            case .write:
                counts.writes += 1
                if backend.readOnly {
                    status = EPERM
                } else if let payload = request.payload {
                    let span = UnsafeRawBufferPointer(rebasing: payload[0..<request.length])
                    do { try backend.write(from: span, at: request.offset) } catch { status = fail(error, "write") }
                }
            case .flush:
                counts.flushes += 1
                do { try backend.flush() } catch { status = fail(error, "flush") }
            case .trim:
                break
            case .disconnect:
                try? backend.flush()
                return
            }
            var reply = [UInt8]()
            reply.reserveCapacity(16)
            appendBE(&reply, Self.replyMagic)
            appendBE(&reply, UInt32(bitPattern: status))
            reply += request.handle
            guard reply.withUnsafeBytes({ writeAll($0) }) else { return }
            if let data { guard writeAll(data) else { return } }
        }
    }

    private func fail(_ error: Error, _ what: String) -> Int32 {
        counts.errors += 1
        log.error("NBD \(what) failed: \(String(describing: error))")
        return EIO
    }

    private func readExactly(_ bytes: inout [UInt8]) -> Bool {
        bytes.withUnsafeMutableBytes { readExactly($0) }
    }

    private func readExactly(_ buf: UnsafeMutableRawBufferPointer) -> Bool {
        var off = 0
        while off < buf.count {
            let n = Darwin.read(fd, buf.baseAddress! + off, buf.count - off)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    private func writeAll(_ buf: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        while off < buf.count {
            let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

private func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
private func be32(_ b: [UInt8], _ i: Int) -> UInt32 { b[i..<i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
private func be64(_ b: [UInt8], _ i: Int) -> UInt64 { b[i..<i + 8].reduce(0) { $0 << 8 | UInt64($1) } }
private func appendBE(_ b: inout [UInt8], _ v: UInt32) {
    b += [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
}
