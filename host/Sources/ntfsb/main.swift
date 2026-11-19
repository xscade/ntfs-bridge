import Foundation
import NTFSBridgeCore

let usage = """
usage: ntfsb --guest DIR IMAGE COMMAND
  mkfs LABEL     format IMAGE as NTFS (destroys its contents)
  check          run ntfsfix -n (read-only consistency check)
  ls [PATH]      list a directory (read-only mount)
  cat PATH       print a file (read-only mount)
  selftest       exercise every operation read-write, remount, then check
  repair         run ntfsfix (fixes $MFTMirr, resets the journal)
  mount          mount read-write and report driver mode and note
  put NAME TEXT  write a file at the root
  crash          write, then stop the guest without unmounting
  bench PATH [CHUNK]  time reading a file
  stress [MB]    parallel large writes, reads and syncs; fails if I/O stalls
"""

struct Failure: Error, CustomStringConvertible {
    var description: String
}

func expect(_ ok: Bool, _ what: String) throws {
    if !ok { throw Failure(description: "FAILED: \(what)") }
    print("ok  \(what)")
}

func resolve(_ client: BridgeClient, root: UInt64, _ path: String) async throws -> Attr {
    var attr = try await client.getattr(root)
    for part in path.split(separator: "/") {
        attr = try await client.lookup(attr.ino, String(part))
    }
    return attr
}

func listAll(_ client: BridgeClient, _ ino: UInt64) async throws -> [DirEntry] {
    var all: [DirEntry] = []
    var cookie: UInt64 = 0
    while true {
        let page = try await client.readdir(ino, cookie: cookie, max: 128)
        all += page.entries
        if page.eof || page.entries.isEmpty { return all }
        cookie = page.entries.last!.nextCookie
    }
}

struct Session {
    let vm: GuestVM
    let client: BridgeClient

    static func boot(guest: URL, image: URL, readOnly: Bool) async throws -> Session {
        let vm = try GuestVM(kernel: guest.appending(path: "Image"),
                             initrd: guest.appending(path: "initrd.gz"),
                             disk: try FileBackend(url: image, readOnly: readOnly),
                             consoleLog: URL(filePath: "/tmp/ntfsb-console.log"))
        let start = ContinuousClock.now
        let client = try await vm.start()
        print("booted \(try await client.hello()) in \(ContinuousClock.now - start)")
        return Session(vm: vm, client: client)
    }

    func shutdown() async throws {
        try await client.unmount()
        if !(await vm.waitUntilStopped(timeout: .seconds(10))) {
            await vm.forceStop()
            throw Failure(description: "guest did not power off after unmount")
        }
    }
}

func selftest(guest: URL, image: URL) async throws {
    let testDir = "bridge-test-\(Int(Date().timeIntervalSince1970))"
    var s = try await Session.boot(guest: guest, image: image, readOnly: false)
    var info = try await s.client.mount(readOnly: false)
    try await expect(!info.readOnly, "mounted read-write (label '\(info.label)')")
    let c = s.client
    let root = info.root.ino

    let dir = try await c.create(root, testDir, kind: .directory, mode: 0o755)
    try await expect(dir.isDirectory, "mkdir")
    let file = try await c.create(dir.ino, "data.bin", kind: .file, mode: 0o644)
    var payload = Data(count: 5 << 20 + 12345)
    payload.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
    var off = 0
    while off < payload.count {
        let chunk = payload[off..<min(off + (1 << 20), payload.count)]
        let n = try await c.write(file.ino, offset: UInt64(off), data: Data(chunk))
        off += Int(n)
    }
    var readBack = Data()
    while readBack.count < payload.count {
        readBack += try await c.read(file.ino, offset: UInt64(readBack.count), length: 1 << 20)
    }
    try await expect(readBack == payload, "wrote and read back \(payload.count) random bytes")
    try await expect(try await c.getattr(file.ino).size == UInt64(payload.count), "size after write")

    let unicode = "Résumé – 日本語 📁.txt"
    let u = try await c.create(dir.ino, unicode, kind: .file, mode: 0o644)
    _ = try await c.write(u.ino, offset: 0, data: Data("hello".utf8))
    try await expect(try await c.lookup(dir.ino, unicode).ino == u.ino, "unicode file name round-trips")

    let sub = try await c.create(dir.ino, "sub", kind: .directory, mode: 0o755)
    for i in 0..<300 {
        _ = try await c.create(sub.ino, String(format: "f%03d", i), kind: .file, mode: 0o644)
    }
    let listed = try await listAll(c, sub.ino)
    try await expect(listed.count == 300, "paged readdir returns all 300 entries")

    try await c.rename(dir.ino, "sub", dir.ino, "sub-renamed")
    try await expect(try await c.getattr(sub.ino).isDirectory, "directory ino valid after rename")
    let deep = try await c.lookup(sub.ino, "f042")
    try await expect(try await c.read(deep.ino, offset: 0, length: 10).isEmpty, "child path follows parent rename")

    var t = BridgeClient.SetAttr()
    t.size = 1000
    t.mtimeNs = 1_600_000_000_123_000_000
    let truncated = try await c.setattr(file.ino, t)
    try await expect(truncated.size == 1000, "truncate")
    try await expect(truncated.mtimeNs / 100 == t.mtimeNs! / 100, "set mtime (100ns NTFS precision)")

    _ = try await c.create(dir.ino, "link", kind: .symlink, mode: 0o777, linkTarget: "data.bin")
    let link = try await c.lookup(dir.ino, "link")
    try await expect(link.isSymlink, "symlink created")
    try await expect(try await c.readlink(link.ino) == "data.bin", "readlink")

    try await c.remove(sub.ino, "f000", isDirectory: false)
    do {
        _ = try await c.lookup(sub.ino, "f000")
        try expect(false, "removed file is gone")
    } catch let e as BridgeError {
        try expect(e.errno == ENOENT, "removed file is gone (ENOENT)")
    }
    do {
        try await c.remove(dir.ino, "sub-renamed", isDirectory: true)
        try expect(false, "rmdir of non-empty directory fails")
    } catch let e as BridgeError {
        try expect(e.errno == ENOTEMPTY, "rmdir of non-empty directory fails (ENOTEMPTY)")
    }
    let before = try await c.statfs()
    try await c.sync()
    try await s.shutdown()
    print("unmounted cleanly; remounting read-only to check persistence")

    s = try await Session.boot(guest: guest, image: image, readOnly: true)
    info = try await s.client.mount(readOnly: true)
    let again = try await resolve(s.client, root: info.root.ino, testDir + "/data.bin")
    let head = try await s.client.read(again.ino, offset: 0, length: 1000)
    try await expect(head == payload.prefix(1000), "data persisted across remount")
    try await expect(try await listAll(s.client, try await resolve(s.client, root: info.root.ino,
                                                                   testDir + "/sub-renamed").ino).count == 299,
                     "directory contents persisted")
    try await expect(info.statfs.blocksFree == before.blocksFree, "free space consistent across remount")
    try await s.shutdown()

    s = try await Session.boot(guest: guest, image: image, readOnly: true)
    let check = try await s.client.check()
    print(check.output.trimmingCharacters(in: .whitespacesAndNewlines))
    try await expect(check.exitCode == 0, "ntfsfix -n reports a consistent volume")
    try await s.shutdown()
    print("SELFTEST PASSED")
}

/// Writes and reads several large files in parallel with periodic syncs: the
/// load that once deadlocked the NBD link. A watchdog fails the run if no
/// operation completes for 60 seconds.
func stress(guest: URL, image: URL, megabytes: Int) async throws {
    let s = try await Session.boot(guest: guest, image: image, readOnly: false)
    let info = try await s.client.mount(readOnly: false)
    let client = s.client
    let progress = Progress(totalUnitCount: 0)
    let watchdog = Task.detached {
        var last = Int64(-1)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            let now = progress.completedUnitCount
            if now == last {
                print("FAILED: no I/O completed for 60 s (deadlock)")
                exit(2)
            }
            last = now
        }
    }
    let chunk = 1 << 20
    let files = 6
    var inodes: [UInt64] = []
    for i in 0..<files {
        inodes.append(try await client.create(info.root.ino, "stress-\(i).bin", kind: .file, mode: 0o644).ino)
    }
    let start = ContinuousClock.now
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (i, ino) in inodes.enumerated() {
            group.addTask {
                let data = Data(repeating: UInt8(i + 1), count: chunk)
                for n in 0..<megabytes {
                    _ = try await client.write(ino, offset: UInt64(n * chunk), data: data)
                    progress.completedUnitCount += 1
                    // Read back what an earlier pass wrote, so reads and writes overlap.
                    if n > 0 {
                        let back = try await client.read(ino, offset: UInt64((n - 1) * chunk), length: UInt32(chunk))
                        try expectQuiet(back.count == chunk && back.allSatisfy { $0 == UInt8(i + 1) },
                                        "file \(i) block \(n - 1) reads back")
                        progress.completedUnitCount += 1
                    }
                    if n % 16 == 15 {
                        try await client.sync()
                        progress.completedUnitCount += 1
                    }
                }
            }
        }
        try await group.waitForAll()
    }
    try await client.sync()
    let secs = (ContinuousClock.now - start) / .seconds(1)
    print(String(format: "wrote and verified %d MB in %.1fs", files * megabytes, secs))
    for i in 0..<files { try await client.remove(info.root.ino, "stress-\(i).bin", isDirectory: false) }
    watchdog.cancel()
    try await s.shutdown()
    print("STRESS PASSED")
}

func expectQuiet(_ ok: Bool, _ what: String) throws {
    if !ok { throw Failure(description: "FAILED: \(what)") }
}

func run() async throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 4, args[0] == "--guest" else { throw Failure(description: usage) }
    let guest = URL(filePath: args[1])
    let image = URL(filePath: args[2])
    args.removeFirst(3)
    let command = args.removeFirst()
    switch command {
    case "mkfs":
        let s = try await Session.boot(guest: guest, image: image, readOnly: false)
        print(try await s.client.mkfs(label: args.first ?? "NTFS"))
        try await s.shutdown()
    case "check":
        let s = try await Session.boot(guest: guest, image: image, readOnly: true)
        let r = try await s.client.check()
        print(r.output)
        try await s.shutdown()
        if r.exitCode != 0 { throw Failure(description: "ntfsfix exit \(r.exitCode)") }
    case "ls", "cat":
        let s = try await Session.boot(guest: guest, image: image, readOnly: true)
        let info = try await s.client.mount(readOnly: true)
        let target = try await resolve(s.client, root: info.root.ino, args.first ?? "")
        if command == "ls" {
            for e in try await listAll(s.client, target.ino) {
                print(String(format: "%@ %12llu  %@", e.attr.isDirectory ? "d" : "-", e.attr.size, e.name))
            }
        } else {
            var off: UInt64 = 0
            while true {
                let d = try await s.client.read(target.ino, offset: off, length: 1 << 20)
                if d.isEmpty { break }
                FileHandle.standardOutput.write(d)
                off += UInt64(d.count)
            }
        }
        try await s.shutdown()
    case "selftest":
        try await selftest(guest: guest, image: image)
    case "repair":
        let s = try await Session.boot(guest: guest, image: image, readOnly: false)
        let r = try await s.client.check(repair: true)
        print(r.output)
        try await s.shutdown()
        if r.exitCode != 0 { throw Failure(description: "ntfsfix exit \(r.exitCode)") }
    case "mount":
        let s = try await Session.boot(guest: guest, image: image, readOnly: false)
        let info = try await s.client.mount(readOnly: false)
        print("readOnly=\(info.readOnly) label=\(info.label)\nnote=\(info.note)")
        try await s.shutdown()
    case "put":
        guard args.count >= 2 else { throw Failure(description: usage) }
        let s = try await Session.boot(guest: guest, image: image, readOnly: false)
        let info = try await s.client.mount(readOnly: false)
        let file = try await s.client.create(info.root.ino, args[0], kind: .file, mode: 0o644)
        _ = try await s.client.write(file.ino, offset: 0, data: Data(args[1].utf8))
        print("wrote \(args[0]) readOnly=\(info.readOnly)")
        try await s.shutdown()
    case "crash":
        let s = try await Session.boot(guest: guest, image: image, readOnly: false)
        let info = try await s.client.mount(readOnly: false)
        let file = try await s.client.create(info.root.ino, "crash-\(Int(Date().timeIntervalSince1970)).txt", kind: .file, mode: 0o644)
        _ = try await s.client.write(file.ino, offset: 0, data: Data(repeating: 0x41, count: 1 << 20))
        await s.vm.forceStop()
        print("stopped the guest without unmounting")
    case "fill":
        guard args.count >= 2, let mb = Int(args[1]) else { throw Failure(description: usage) }
        let s = try await Session.boot(guest: guest, image: image, readOnly: false)
        let info = try await s.client.mount(readOnly: false)
        let file = try await s.client.create(info.root.ino, args[0], kind: .file, mode: 0o644)
        let block = Data((0..<(8 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) })
        for i in 0..<(mb / 8) { _ = try await s.client.write(file.ino, offset: UInt64(i) * UInt64(block.count), data: block) }
        print("wrote \(mb) MB to \(args[0])")
        try await s.shutdown()
    case "bench":
        let s = try await Session.boot(guest: guest, image: image, readOnly: true)
        let info = try await s.client.mount(readOnly: true)
        let target = try await resolve(s.client, root: info.root.ino, args.first ?? "")
        let chunk = UInt32(args.count > 1 ? Int(args[1])! : 1 << 20)
        let start = ContinuousClock.now
        var off: UInt64 = 0
        while true {
            let d = try await s.client.read(target.ino, offset: off, length: chunk)
            if d.isEmpty { break }
            off += UInt64(d.count)
        }
        let secs = (ContinuousClock.now - start) / .seconds(1)
        print(String(format: "read %.0f MB in %.2fs = %.1f MB/s (chunk %u)", Double(off) / 1e6, secs, Double(off) / 1e6 / secs, chunk))
        try await s.shutdown()
    case "stress":
        try await stress(guest: guest, image: image, megabytes: Int(args.first ?? "") ?? 96)
    default:
        throw Failure(description: usage)
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
