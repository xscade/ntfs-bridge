import Foundation

public enum BridgeError: Error, CustomStringConvertible {
    case posix(Int32, String)
    case malformedReply
    case disconnected
    case vm(String)

    public var errno: Int32 {
        switch self {
        case .posix(let e, _): linuxToDarwin(e)
        case .malformedReply, .disconnected, .vm: EIO
        }
    }

    public var description: String {
        switch self {
        case .posix(let e, let detail): "guest errno \(e): \(detail)"
        case .malformedReply: "malformed reply from guest"
        case .disconnected: "guest connection closed"
        case .vm(let detail): detail
        }
    }
}

/// Linux and Darwin share errno values below 35; the rest that the guest can
/// plausibly return are mapped here.
func linuxToDarwin(_ e: Int32) -> Int32 {
    switch e {
    case 0..<35: e
    case 36: ENAMETOOLONG
    case 38: ENOSYS
    case 39: ENOTEMPTY
    case 40: ELOOP
    case 61: ENODATA
    case 95: ENOTSUP
    case 116: ESTALE
    case 122: EDQUOT
    default: EIO
    }
}

public struct MountInfo: Sendable {
    public var readOnly: Bool
    public var label: String
    public var note: String
    public var root: Attr
    public var statfs: Statfs
}

/// Request/response client for the guest agent. Calls may run concurrently;
/// replies are matched to callers by request id.
///
/// `lock` guards the pending table and `sendLock` only orders frames on the
/// socket. The reader must never wait for a sender: a send can block until the
/// guest drains its side, and the guest only drains it while its replies are
/// being read. Sharing one lock deadlocks both under load.
public final class BridgeClient: @unchecked Sendable {
    private let fd: Int32
    private let keepAlive: AnyObject?
    private let lock = NSLock()
    private let sendLock = NSLock()
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var closed = false

    init(fd: Int32, keepAlive: AnyObject?) {
        self.fd = fd
        self.keepAlive = keepAlive
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "ntfsbridge.reader"
        thread.start()
    }

    func call(_ op: Op, _ build: (inout WireWriter) -> Void = { _ in }) async throws -> WireReader {
        var body = WireWriter()
        build(&body)
        let reply = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                cont.resume(throwing: BridgeError.disconnected)
                return
            }
            let id = nextID
            nextID += 1
            pending[id] = cont
            lock.unlock()
            var frame = WireWriter()
            frame.u32(UInt32(body.data.count))
            frame.u64(id)
            frame.u8(op.rawValue)
            frame.data.append(body.data)
            sendLock.lock()
            let ok = writeAll(frame.data)
            sendLock.unlock()
            if !ok { fail(id) }
        }
        return WireReader(reply)
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                off += n
            }
            return true
        }
    }

    private func fail(_ id: UInt64) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(throwing: BridgeError.disconnected)
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            var off = 0
            while off < count {
                let n = Darwin.read(fd, buf.baseAddress! + off, count - off)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        return ok ? data : nil
    }

    private func readLoop() {
        while let head = readExactly(16) {
            var r = WireReader(head)
            guard let len = try? r.u32(), let id = try? r.u64(), let err = try? r.i32(),
                  let body = readExactly(Int(len)) else { break }
            lock.lock()
            let cont = pending.removeValue(forKey: id)
            lock.unlock()
            if err == 0 {
                cont?.resume(returning: body)
            } else {
                var br = WireReader(body)
                cont?.resume(throwing: BridgeError.posix(err, (try? br.str()) ?? ""))
            }
        }
        lock.lock()
        closed = true
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for cont in waiting.values { cont.resume(throwing: BridgeError.disconnected) }
    }

    // MARK: Operations

    public func hello() async throws -> String {
        var r = try await call(.hello)
        return try r.str()
    }

    public func mount(readOnly: Bool) async throws -> MountInfo {
        var r = try await call(.mount) { $0.u8(readOnly ? 1 : 0) }
        return MountInfo(readOnly: try r.u8() != 0, label: try r.str(), note: try r.str(),
                         root: try r.attr(), statfs: try r.statfs())
    }

    public func statfs() async throws -> Statfs {
        var r = try await call(.statfs)
        return try r.statfs()
    }

    public func getattr(_ ino: UInt64) async throws -> Attr {
        var r = try await call(.getattr) { $0.u64(ino) }
        return try r.attr()
    }

    public func lookup(_ parent: UInt64, _ name: String) async throws -> Attr {
        var r = try await call(.lookup) { $0.u64(parent); $0.str(name) }
        return try r.attr()
    }

    public func readdir(_ ino: UInt64, cookie: UInt64, max: UInt32) async throws -> (entries: [DirEntry], eof: Bool) {
        var r = try await call(.readdir) { $0.u64(ino); $0.u64(cookie); $0.u32(max) }
        let eof = try r.u8() != 0
        let n = try r.u32()
        var entries: [DirEntry] = []
        entries.reserveCapacity(Int(n))
        for _ in 0..<n {
            entries.append(DirEntry(name: try r.str(), nextCookie: try r.u64(), attr: try r.attr()))
        }
        return (entries, eof)
    }

    public func read(_ ino: UInt64, offset: UInt64, length: UInt32) async throws -> Data {
        var r = try await call(.read) { $0.u64(ino); $0.u64(offset); $0.u32(length) }
        return try r.bytes()
    }

    public func write(_ ino: UInt64, offset: UInt64, data: Data) async throws -> UInt32 {
        var r = try await call(.write) { $0.u64(ino); $0.u64(offset); $0.bytes(data) }
        return try r.u32()
    }

    public func create(_ parent: UInt64, _ name: String, kind: ItemKind, mode: UInt32,
                       linkTarget: String = "") async throws -> Attr {
        var r = try await call(.create) {
            $0.u64(parent); $0.str(name); $0.u8(kind.rawValue); $0.u32(mode); $0.str(linkTarget)
        }
        return try r.attr()
    }

    public func remove(_ parent: UInt64, _ name: String, isDirectory: Bool) async throws {
        _ = try await call(.remove) { $0.u64(parent); $0.str(name); $0.u8(isDirectory ? 1 : 0) }
    }

    public func rename(_ srcParent: UInt64, _ srcName: String, _ dstParent: UInt64, _ dstName: String) async throws {
        _ = try await call(.rename) { $0.u64(srcParent); $0.str(srcName); $0.u64(dstParent); $0.str(dstName) }
    }

    public struct SetAttr: Sendable {
        public var mode: UInt32?
        public var uid: UInt32?
        public var gid: UInt32?
        public var size: UInt64?
        public var atimeNs: Int64?
        public var mtimeNs: Int64?
        public init() {}
    }

    public func setattr(_ ino: UInt64, _ s: SetAttr) async throws -> Attr {
        var mask: UInt32 = 0
        if s.mode != nil { mask |= 1 }
        if s.uid != nil { mask |= 2 }
        if s.gid != nil { mask |= 4 }
        if s.size != nil { mask |= 8 }
        if s.atimeNs != nil { mask |= 16 }
        if s.mtimeNs != nil { mask |= 32 }
        var r = try await call(.setattr) {
            $0.u64(ino); $0.u32(mask); $0.u32(s.mode ?? 0); $0.u32(s.uid ?? 0); $0.u32(s.gid ?? 0)
            $0.u64(s.size ?? 0); $0.i64(s.atimeNs ?? 0); $0.i64(s.mtimeNs ?? 0)
        }
        return try r.attr()
    }

    public func readlink(_ ino: UInt64) async throws -> String {
        var r = try await call(.readlink) { $0.u64(ino) }
        return try r.str()
    }

    public func sync() async throws { _ = try await call(.sync) }
    /// Unmounts, then half-closes the connection: the guest powers off once it
    /// sees end-of-file, so this reply is always delivered first.
    public func unmount() async throws {
        _ = try await call(.unmount)
        Darwin.shutdown(fd, SHUT_WR)
    }

    public func mkfs(label: String) async throws -> String {
        var r = try await call(.mkfs) { $0.str(label) }
        return try r.str()
    }

    /// Runs ntfsfix on the unmounted volume: `-n` (no changes) unless `repair`.
    public func check(repair: Bool = false) async throws -> (exitCode: Int32, output: String) {
        var r = try await call(.check) { $0.u8(repair ? 1 : 0) }
        return (try r.i32(), try r.str())
    }
}
