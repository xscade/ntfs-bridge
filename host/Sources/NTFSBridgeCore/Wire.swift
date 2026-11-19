import Foundation

/// Operation codes, matching PROTOCOL.md.
public enum Op: UInt8, Sendable {
    case hello = 1, mount, statfs, getattr, lookup, readdir, read, write
    case create, remove, rename, setattr, readlink, sync, unmount, mkfs, check
}

public enum ItemKind: UInt8, Sendable {
    case file = 1, directory, symlink
}

public struct Attr: Sendable {
    public var ino: UInt64
    public var mode: UInt32
    public var nlink: UInt32
    public var uid: UInt32
    public var gid: UInt32
    public var size: UInt64
    public var allocated: UInt64
    public var atimeNs: Int64
    public var mtimeNs: Int64
    public var ctimeNs: Int64
    public var btimeNs: Int64

    public var isDirectory: Bool { mode & 0o170000 == 0o040000 }
    public var isSymlink: Bool { mode & 0o170000 == 0o120000 }
    public var kind: ItemKind { isDirectory ? .directory : isSymlink ? .symlink : .file }
}

public struct Statfs: Sendable {
    public var blockSize: UInt64
    public var blocks: UInt64
    public var blocksFree: UInt64
    public var blocksAvail: UInt64
    public var files: UInt64
    public var filesFree: UInt64
    public var nameMax: UInt32
}

public struct DirEntry: Sendable {
    public var name: String
    public var nextCookie: UInt64
    public var attr: Attr
}

struct WireReader {
    private var data: Data
    private var pos: Int

    init(_ data: Data) {
        self.data = data
        pos = data.startIndex
    }

    mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, pos + n <= data.endIndex else { throw BridgeError.malformedReply }
        defer { pos += n }
        return data[pos..<pos + n]
    }

    private mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let bytes = try take(MemoryLayout<T>.size)
        return bytes.reversed().reduce(T.zero) { $0 << 8 | T(truncatingIfNeeded: $1) }
    }

    mutating func u8() throws -> UInt8 { try int(UInt8.self) }
    mutating func u32() throws -> UInt32 { try int(UInt32.self) }
    mutating func i32() throws -> Int32 { try int(Int32.self) }
    mutating func u64() throws -> UInt64 { try int(UInt64.self) }
    mutating func i64() throws -> Int64 { try int(Int64.self) }
    mutating func bytes() throws -> Data { Data(try take(Int(try u32()))) }
    mutating func str() throws -> String { String(decoding: try bytes(), as: UTF8.self) }

    mutating func attr() throws -> Attr {
        Attr(ino: try u64(), mode: try u32(), nlink: try u32(), uid: try u32(), gid: try u32(),
             size: try u64(), allocated: try u64(), atimeNs: try i64(), mtimeNs: try i64(),
             ctimeNs: try i64(), btimeNs: try i64())
    }

    mutating func statfs() throws -> Statfs {
        Statfs(blockSize: try u64(), blocks: try u64(), blocksFree: try u64(),
               blocksAvail: try u64(), files: try u64(), filesFree: try u64(), nameMax: try u32())
    }
}

struct WireWriter {
    var data = Data()

    mutating func int<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func u8(_ v: UInt8) { int(v) }
    mutating func u32(_ v: UInt32) { int(v) }
    mutating func u64(_ v: UInt64) { int(v) }
    mutating func i64(_ v: Int64) { int(v) }
    mutating func bytes(_ v: Data) {
        u32(UInt32(v.count))
        data.append(v)
    }
    mutating func str(_ v: String) { bytes(Data(v.utf8)) }
}
