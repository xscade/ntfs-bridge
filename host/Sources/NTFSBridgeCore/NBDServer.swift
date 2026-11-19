import Foundation
import os

/// Serves a BlockBackend to the guest kernel's NBD client. The guest configures
/// the device with ioctls, so only the transmission phase is spoken here
/// (big-endian simple replies, one request at a time).
final class NBDServer: @unchecked Sendable {
    private enum Command: UInt16 {
        case read = 0, write = 1, disconnect = 2, flush = 3, trim = 4
    }

    private static let requestMagic: UInt32 = 0x2560_9513
    private static let replyMagic: UInt32 = 0x6744_6698
    private static let maxRequest = 32 << 20

    private let fd: Int32
    private let backend: BlockBackend
    private let keepAlive: AnyObject
    private let log = Logger(subsystem: "ntfsbridge", category: "nbd")
    private(set) var counts = (reads: 0, writes: 0, flushes: 0, errors: 0)

    init(fd: Int32, backend: BlockBackend, keepAlive: AnyObject) {
        self.fd = fd
        self.backend = backend
        self.keepAlive = keepAlive
    }

    func start() {
        let thread = Thread { [self] in serve() }
        thread.name = "ntfsbridge.nbd"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func serve() {
        var header = [UInt8](repeating: 0, count: 28)
        var buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 4096)
        defer { buffer.deallocate() }
        while readExactly(&header) {
            let magic = be32(header, 0)
            let type = be16(header, 6)
            let handle = Array(header[8..<16])
            let offset = be64(header, 16)
            let length = Int(be32(header, 24))
            guard magic == Self.requestMagic, length <= Self.maxRequest,
                  let command = Command(rawValue: type & 0x00ff) else {
                log.error("bad NBD request magic=\(magic) type=\(type) len=\(length)")
                return
            }
            if command == .disconnect {
                try? backend.flush()
                return
            }
            if length > buffer.count {
                buffer.deallocate()
                buffer = .allocate(byteCount: length, alignment: 4096)
            }
            let span = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<length])
            var status: Int32 = 0
            switch command {
            case .read:
                counts.reads += 1
                do { try backend.read(into: span, at: offset) } catch { status = fail(error, "read") }
            case .write:
                counts.writes += 1
                guard readExactly(span) else { return }
                if backend.readOnly {
                    status = EPERM
                } else {
                    do { try backend.write(from: UnsafeRawBufferPointer(span), at: offset) } catch { status = fail(error, "write") }
                }
            case .flush:
                counts.flushes += 1
                do { try backend.flush() } catch { status = fail(error, "flush") }
            case .trim:
                break
            case .disconnect:
                return
            }
            var reply = [UInt8]()
            reply.reserveCapacity(16)
            appendBE(&reply, Self.replyMagic)
            appendBE(&reply, UInt32(bitPattern: status))
            reply += handle
            guard writeAll(UnsafeRawBufferPointer(start: reply, count: reply.count)) else { return }
            if command == .read, status == 0 {
                guard writeAll(UnsafeRawBufferPointer(span)) else { return }
            }
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
