import Foundation

/// The disk the guest sees as /dev/nbd0. Offsets and lengths arriving here are
/// multiples of `blockSize`.
public protocol BlockBackend: AnyObject {
    var size: UInt64 { get }
    var blockSize: UInt32 { get }
    var readOnly: Bool { get }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws
    func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws
    func flush() throws
}

struct POSIXFailure: Error, CustomStringConvertible {
    var code: Int32
    var what: String
    var description: String { "\(what): \(String(cString: strerror(code)))" }
}

/// A raw disk image file.
public final class FileBackend: BlockBackend {
    private let fd: Int32
    public let size: UInt64
    public let blockSize: UInt32 = 512
    public let readOnly: Bool

    public init(url: URL, readOnly: Bool) throws {
        fd = open(url.path, readOnly ? O_RDONLY : O_RDWR)
        guard fd >= 0 else { throw POSIXFailure(code: errno, what: "open \(url.path)") }
        var st = stat()
        fstat(fd, &st)
        size = UInt64(st.st_size) / 512 * 512
        self.readOnly = readOnly
    }

    deinit { close(fd) }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws {
        var done = 0
        while done < buffer.count {
            let n = pread(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw POSIXFailure(code: n == 0 ? EIO : errno, what: "pread") }
            done += n
        }
    }

    public func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws {
        var done = 0
        while done < buffer.count {
            let n = pwrite(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw POSIXFailure(code: errno, what: "pwrite") }
            done += n
        }
    }

    public func flush() throws {
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw POSIXFailure(code: errno, what: "fsync") }
    }
}
