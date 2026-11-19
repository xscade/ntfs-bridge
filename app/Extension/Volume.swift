import FSKit
import Foundation

/// An FSKit item backed by one inode in the guest.
final class BridgeItem: FSItem {
    let ino: UInt64
    var attr: Attr

    init(attr: Attr) {
        ino = attr.ino
        self.attr = attr
        super.init()
    }
}

/// One mounted NTFS partition. Every operation is forwarded to the guest agent;
/// the guest's ntfs3 driver does the NTFS work.
final class NTFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    private let backend: DeviceBackend
    private var guest: GuestVM?
    private var client: BridgeClient?
    private var readOnly: Bool
    private var root: BridgeItem?
    private var items: [UInt64: BridgeItem] = [:]
    private var lastStatfs: Statfs?
    private let lock = NSLock()

    private let bsdName: String

    init(device: FSBlockDeviceResource, uuid: UUID, label: String?, readOnly: Bool) {
        bsdName = device.bsdName
        backend = DeviceBackend(device: device, readOnly: readOnly)
        self.readOnly = readOnly
        super.init(volumeID: FSVolume.Identifier(uuid: uuid), volumeName: FSFileName(string: label ?? "NTFS"))
    }

    private func bridge() throws -> BridgeClient {
        guard let client else { throw fs_errorForPOSIXError(ENXIO) }
        return client
    }

    /// Runs an async body and delivers its result to an FSKit reply handler.
    private func reply<T>(_ handler: @escaping (T?, Error?) -> Void, _ body: @escaping () async throws -> T) {
        Task {
            do {
                handler(try await body(), nil)
            } catch {
                handler(nil, posix(error))
            }
        }
    }

    private func posix(_ error: Error) -> Error {
        if let e = error as? BridgeError { return fs_errorForPOSIXError(e.errno) }
        return error
    }

    private func item(for attr: Attr) -> BridgeItem {
        lock.lock()
        defer { lock.unlock() }
        if let existing = items[attr.ino] {
            existing.attr = attr
            return existing
        }
        let created = BridgeItem(attr: attr)
        items[attr.ino] = created
        return created
    }

    /// FSKit has been seen handing a null item after an attribute fault; taking the
    /// parameter as optional turns that into an error instead of a crash.
    private func node(_ item: FSItem?) throws -> BridgeItem {
        guard let bridged = item as? BridgeItem else { throw fs_errorForPOSIXError(EINVAL) }
        return bridged
    }

    private func name(_ name: FSFileName) throws -> String {
        guard let s = name.string else { throw fs_errorForPOSIXError(EILSEQ) }
        return s
    }

    private func guardWritable() throws {
        if readOnly { throw fs_errorForPOSIXError(EROFS) }
    }

    // MARK: Volume lifecycle

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supports64BitObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsSparseFiles = true
        caps.supports2TBFiles = true
        caps.supportsFastStatFS = true
        caps.caseFormat = .sensitive
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "ntfs")
        guard let s = lastStatfs else { return result }
        result.blockSize = Int(s.blockSize)
        result.ioSize = 1 << 20
        result.totalBlocks = s.blocks
        result.freeBlocks = s.blocksFree
        result.availableBlocks = s.blocksAvail
        result.usedBlocks = s.blocks - s.blocksFree
        result.totalBytes = s.blocks * s.blockSize
        result.freeBytes = s.blocksFree * s.blockSize
        result.availableBytes = s.blocksAvail * s.blockSize
        result.usedBytes = result.totalBytes - result.freeBytes
        result.totalFiles = s.files
        result.freeFiles = s.filesFree
        return result
    }

    private func refreshStatfs() {
        Task { if let s = try? await client?.statfs() { lastStatfs = s } }
    }

    /// Read after `mount(options:)`, which follows `activate`; by then the guest has
    /// said whether it fell back to read-only (Fast Startup, dirty or damaged volume),
    /// so macOS marks the mount read-only and Finder shows it locked.
    var requestedMountOptions: FSVolume.MountOptions { readOnly ? .readOnly : [] }

    var maximumLinkCount: Int { 1024 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }
    var maximumXattrSize: Int { 0 }

    func activate(options: FSTaskOptions, replyHandler: @escaping (FSItem?, Error?) -> Void) {
        reply(replyHandler) { [self] in
            let resources = Bundle(for: NTFSVolume.self)
            guard let kernel = resources.url(forResource: "Image", withExtension: nil),
                  let initrd = resources.url(forResource: "initrd", withExtension: "gz") else {
                throw fs_errorForPOSIXError(ENOENT)
            }
            let console = FileManager.default.temporaryDirectory.appending(path: "ntfsbridge-console.log")
            let vm = try GuestVM(kernel: kernel, initrd: initrd, disk: backend, consoleLog: console)
            vm.onStop { reason in log.error("\(reason, privacy: .public)") }
            let client = try await vm.start()
            let info = try await client.mount(readOnly: readOnly)
            if !info.note.isEmpty { log.notice("\(info.note, privacy: .public)") }
            MountNotes.publish(bsdName: bsdName, readOnly: info.readOnly, note: info.note)
            guest = vm
            self.client = client
            readOnly = info.readOnly
            lastStatfs = info.statfs
            if !info.label.isEmpty { name = FSFileName(string: info.label) }
            let rootItem = item(for: info.root)
            root = rootItem
            log.info("activated '\(info.label, privacy: .public)' readOnly=\(info.readOnly)")
            return rootItem
        }
    }

    func deactivate(options: FSDeactivateOptions = [], replyHandler: @escaping (Error?) -> Void) {
        Task {
            await shutdown()
            replyHandler(nil)
        }
    }

    private func shutdown() async {
        guard let vm = guest else { return }
        let secs = Double(backend.readTime.components.seconds) + Double(backend.readTime.components.attoseconds) / 1e18
        log.notice("device reads: \(self.backend.readCalls) calls, \(self.backend.readBytes / 1_000_000) MB in \(secs, format: .fixed(precision: 2))s = \(Double(self.backend.readBytes) / 1e6 / max(secs, 0.001), format: .fixed(precision: 1)) MB/s")
        do {
            try await client?.unmount()
            if !(await vm.waitUntilStopped(timeout: .seconds(15))) { await vm.forceStop() }
        } catch {
            log.error("unmount failed: \(String(describing: error), privacy: .public)")
            await vm.forceStop()
        }
        guest = nil
        client = nil
    }

    func mount(options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void) {
        replyHandler(nil)
    }

    func unmount(replyHandler: @escaping () -> Void) {
        Task { [self] in
            try? await client?.sync()
            replyHandler()
        }
    }

    func synchronize(flags: FSSyncFlags, replyHandler: @escaping (Error?) -> Void) {
        Task { [self] in
            do {
                if !readOnly { try await bridge().sync() }
                replyHandler(nil)
            } catch {
                replyHandler(posix(error))
            }
        }
    }

    // MARK: Items

    func getAttributes(_ desired: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        reply(replyHandler) { [self] in
            let attr = try await bridge().getattr(try node(item).ino)
            try node(item).attr = attr
            return attributes(attr)
        }
    }

    private func attributes(_ a: Attr) -> FSItem.Attributes {
        let out = FSItem.Attributes()
        out.type = switch a.kind {
        case .directory: .directory
        case .symlink: .symlink
        case .file: .file
        }
        out.mode = a.mode & 0o7777
        out.linkCount = a.nlink
        out.flags = 0
        out.uid = getuid()
        out.gid = getgid()
        out.size = a.size
        out.allocSize = a.allocated
        out.fileID = FSItem.Identifier(rawValue: a.ino) ?? .invalid
        out.parentID = .invalid
        out.accessTime = timespec(a.atimeNs)
        out.modifyTime = timespec(a.mtimeNs)
        out.changeTime = timespec(a.ctimeNs)
        out.birthTime = timespec(a.btimeNs)
        return out
    }

    private func timespec(_ ns: Int64) -> Darwin.timespec {
        Darwin.timespec(tv_sec: Int(ns / 1_000_000_000), tv_nsec: Int(ns % 1_000_000_000))
    }

    private func nanoseconds(_ t: Darwin.timespec) -> Int64 {
        Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec)
    }

    func setAttributes(_ request: FSItem.SetAttributesRequest, on item: FSItem,
                       replyHandler: @escaping (FSItem.Attributes?, Error?) -> Void) {
        reply(replyHandler) { [self] in
            try guardWritable()
            var change = BridgeClient.SetAttr()
            var consumed: FSItem.Attribute = []
            if request.isValid(.mode) { change.mode = request.mode; consumed.insert(.mode) }
            if request.isValid(.size) { change.size = request.size; consumed.insert(.size) }
            if request.isValid(.accessTime) { change.atimeNs = nanoseconds(request.accessTime); consumed.insert(.accessTime) }
            if request.isValid(.modifyTime) { change.mtimeNs = nanoseconds(request.modifyTime); consumed.insert(.modifyTime) }
            for ignored in [FSItem.Attribute.uid, .gid, .flags, .birthTime, .changeTime] where request.isValid(ignored) {
                consumed.insert(ignored)
            }
            let attr = try await bridge().setattr(try node(item).ino, change)
            request.consumedAttributes = consumed
            try node(item).attr = attr
            refreshStatfs()
            return attributes(attr)
        }
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        Task { [self] in
            do {
                let attr = try await bridge().lookup(try node(directory).ino, self.name(name))
                replyHandler(item(for: attr), name, nil)
            } catch {
                replyHandler(nil, nil, posix(error))
            }
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler: @escaping (Error?) -> Void) {
        guard let ino = try? node(item).ino else { return replyHandler(nil) }
        lock.lock()
        if items[ino] === item, ino != root?.ino { items[ino] = nil }
        lock.unlock()
        replyHandler(nil)
    }

    func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        reply(replyHandler) { [self] in
            FSFileName(string: try await bridge().readlink(try node(item).ino))
        }
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        Task { [self] in
            do {
                try guardWritable()
                let kind: ItemKind
                switch type {
                case .file: kind = .file
                case .directory: kind = .directory
                default: throw fs_errorForPOSIXError(ENOTSUP)
                }
                let mode = newAttributes.isValid(.mode) ? newAttributes.mode : (kind == .directory ? 0o755 : 0o644)
                var attr = try await bridge().create(try node(directory).ino, self.name(name), kind: kind, mode: mode)
                if newAttributes.isValid(.size), newAttributes.size > 0 {
                    var change = BridgeClient.SetAttr()
                    change.size = newAttributes.size
                    attr = try await bridge().setattr(attr.ino, change)
                }
                refreshStatfs()
                replyHandler(item(for: attr), name, nil)
            } catch {
                replyHandler(nil, nil, posix(error))
            }
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName,
                            replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        Task { [self] in
            do {
                try guardWritable()
                let attr = try await bridge().create(try node(directory).ino, self.name(name), kind: .symlink,
                                                     mode: 0o777, linkTarget: self.name(contents))
                replyHandler(item(for: attr), name, nil)
            } catch {
                replyHandler(nil, nil, posix(error))
            }
        }
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        replyHandler(nil, fs_errorForPOSIXError(ENOTSUP))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                    replyHandler: @escaping (Error?) -> Void) {
        Task { [self] in
            do {
                try guardWritable()
                try await bridge().remove(try node(directory).ino, self.name(name),
                                          isDirectory: try node(item).attr.isDirectory)
                refreshStatfs()
                replyHandler(nil)
            } catch {
                replyHandler(posix(error))
            }
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?,
                    replyHandler: @escaping (FSFileName?, Error?) -> Void) {
        reply(replyHandler) { [self] in
            try guardWritable()
            try await bridge().rename(try node(sourceDirectory).ino, name(sourceName),
                                      try node(destinationDirectory).ino, name(destinationName))
            return destinationName
        }
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        Task { [self] in
            do {
                let dir = try node(directory)
                // Plain readdir (no attributes requested) also lists "." and "..",
                // which occupy cookies 0 and 1; guest cookies are shifted by 2.
                let dots = attributes == nil
                var next = cookie.rawValue
                if dots, next == 0 {
                    guard packer.packEntry(name: FSFileName(string: "."), itemType: .directory,
                                           itemID: FSItem.Identifier(rawValue: dir.ino) ?? .invalid,
                                           nextCookie: FSDirectoryCookie(rawValue: 1), attributes: nil) else {
                        return replyHandler(verifier, nil)
                    }
                    next = 1
                }
                if dots, next == 1 {
                    guard packer.packEntry(name: FSFileName(string: ".."), itemType: .directory,
                                           itemID: .parentOfRoot,
                                           nextCookie: FSDirectoryCookie(rawValue: 2), attributes: nil) else {
                        return replyHandler(verifier, nil)
                    }
                    next = 2
                }
                var guestCookie = dots ? next - 2 : next
                let shift: UInt64 = dots ? 2 : 0
                while true {
                    let page = try await bridge().readdir(dir.ino, cookie: guestCookie, max: 256)
                    for entry in page.entries {
                        let a = self.attributes(entry.attr)
                        guard packer.packEntry(name: FSFileName(string: entry.name), itemType: a.type,
                                               itemID: a.fileID,
                                               nextCookie: FSDirectoryCookie(rawValue: entry.nextCookie + shift),
                                               attributes: attributes == nil ? nil : a) else {
                            return replyHandler(verifier, nil)
                        }
                    }
                    if page.eof || page.entries.isEmpty { break }
                    guestCookie = page.entries.last!.nextCookie
                }
                replyHandler(verifier, nil)
            } catch {
                replyHandler(verifier, posix(error))
            }
        }
    }

    // MARK: Data

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
              replyHandler: @escaping (Int, Error?) -> Void) {
        Task { [self] in
            do {
                let ino = try node(item).ino
                let want = min(length, buffer.length)
                var done = 0
                while done < want {
                    let chunk = try await bridge().read(ino, offset: UInt64(offset) + UInt64(done),
                                                        length: UInt32(min(want - done, 8 << 20)))
                    if chunk.isEmpty { break }
                    buffer.withUnsafeMutableBytes { dst in
                        chunk.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: dst[done..<done + chunk.count]))
                    }
                    done += chunk.count
                }
                replyHandler(done, nil)
            } catch {
                replyHandler(0, posix(error))
            }
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler: @escaping (Int, Error?) -> Void) {
        Task { [self] in
            do {
                try guardWritable()
                let ino = try node(item).ino
                var done = 0
                while done < contents.count {
                    let end = min(done + (8 << 20), contents.count)
                    let n = try await bridge().write(ino, offset: UInt64(offset) + UInt64(done),
                                                     data: contents.subdata(in: done..<end))
                    if n == 0 { throw fs_errorForPOSIXError(EIO) }
                    done += Int(n)
                }
                refreshStatfs()
                replyHandler(done, nil)
            } catch {
                replyHandler(0, posix(error))
            }
        }
    }
}
