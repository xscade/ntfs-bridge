import AppKit
import DiskArbitration
import Foundation
import os

private let log = Logger(subsystem: "com.ravi.NTFSBridge", category: "drives")

/// One NTFS partition as Disk Arbitration describes it.
struct Drive: Identifiable, Equatable {
    enum State: Equatable {
        case unmounted
        case mounted(path: URL, driver: Driver, readOnly: Bool)
    }

    enum Driver: Equatable {
        case bridge
        case other(String)

        var label: String {
            switch self {
            case .bridge: "NTFS Bridge"
            case .other(let kind): kind == "ntfs" ? "macOS (read-only)" : kind
            }
        }
    }

    let bsdName: String
    let name: String
    let size: Int64
    let model: String
    let connection: String
    let isInternal: Bool
    var state: State
    var freeBytes: Int64?
    /// Why NTFS Bridge mounted it the way it did (Fast Startup, chkdsk needed, …).
    var note: String?

    var id: String { bsdName }
    var isMounted: Bool { if case .mounted = state { true } else { false } }
}

/// Watches Disk Arbitration for NTFS partitions and mounts or unmounts them.
@MainActor
final class DriveStore: ObservableObject {
    static let shared = DriveStore()

    @Published private(set) var drives: [Drive] = []
    @Published var busy: Set<String> = []
    @Published var lastError: String? {
        didSet { if let lastError { log.error("\(lastError, privacy: .public)") } }
    }

    private let session: DASession

    private init() {
        session = DASessionCreate(kCFAllocatorDefault)!
        DASessionSetDispatchQueue(session, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let changed: DADiskAppearedCallback = { _, context in
            guard let context else { return }
            let store = Unmanaged<DriveStore>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { store.refresh() }
        }
        DARegisterDiskAppearedCallback(session, nil, changed, context)
        DARegisterDiskDisappearedCallback(session, nil, changed, context)
        let described: DADiskDescriptionChangedCallback = { _, _, context in
            guard let context else { return }
            let store = Unmanaged<DriveStore>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { store.refresh() }
        }
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, described, context)
        refresh()
    }

    func refresh() {
        var found: [Drive] = []
        for bsd in Self.partitionNames() {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
                  let desc = DADiskCopyDescription(disk) as? [String: Any],
                  let drive = Self.drive(bsd: bsd, desc: desc) else { continue }
            found.append(drive)
        }
        found.sort { a, b in
            a.isInternal != b.isInternal ? !a.isInternal : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let notes = MountNotes.read()
        for i in found.indices {
            if case .mounted(_, .bridge, _) = found[i].state, let entry = notes[found[i].bsdName], !entry.note.isEmpty {
                found[i].note = entry.note
            }
        }
        if found != drives {
            for d in found { log.info("drive \(d.bsdName, privacy: .public) '\(d.name, privacy: .public)' \(String(describing: d.state), privacy: .public) note=\(d.note ?? "-", privacy: .public)") }
        }
        drives = found
        takeOverNewDrives()
    }

    // MARK: Automatic take-over

    /// When on, a newly connected NTFS drive is mounted read-write through NTFS Bridge.
    @Published var autoTakeOver: Bool = UserDefaults.standard.object(forKey: "autoTakeOver") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoTakeOver, forKey: "autoTakeOver"); if autoTakeOver { refresh() } }
    }

    /// Drives already handled during this connection: one attempt per plug-in, and a
    /// drive the user unmounted stays unmounted until it is unplugged.
    private var handled: Set<String> = []

    private func takeOverNewDrives() {
        handled.formIntersection(drives.map(\.id))
        guard autoTakeOver else { return }
        for drive in drives where !drive.isInternal && !handled.contains(drive.id) && !busy.contains(drive.id) {
            switch drive.state {
            case .mounted(_, .bridge, _):
                handled.insert(drive.id)
            case .mounted:
                handled.insert(drive.id)
                remount(drive, readOnly: false)
            case .unmounted:
                handled.insert(drive.id)
                mount(drive, readOnly: false)
            }
        }
    }

    private static func partitionNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("disk") && !$0.hasPrefix("diskr") }
    }

    private static func drive(bsd: String, desc: [String: Any]) -> Drive? {
        let content = desc[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let kind = desc[kDADiskDescriptionVolumeKindKey as String] as? String ?? ""
        // MBR partition type 0x07 ("Windows_NTFS") is shared by NTFS and exFAT, so a
        // volume macOS already identified as another file system is never NTFS.
        let otherFileSystems: Set<String> = ["exfat", "msdos", "apfs", "hfs", "udf", "cd9660", "smbfs", "nfs"]
        let isNTFS = kind == "ntfsb" || kind == "ntfs"
            || (content == "Windows_NTFS" && !otherFileSystems.contains(kind))
        guard isNTFS, desc[kDADiskDescriptionMediaLeafKey as String] as? Bool == true else { return nil }

        var state = Drive.State.unmounted
        var free: Int64?
        if let path = desc[kDADiskDescriptionVolumePathKey as String] as? URL {
            var fs = statfs()
            let readOnly = statfs(path.path, &fs) == 0 && (fs.f_flags & UInt32(MNT_RDONLY)) != 0
            free = statfs(path.path, &fs) == 0 ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : nil
            state = .mounted(path: path, driver: kind == "ntfsb" ? .bridge : .other(kind), readOnly: readOnly)
        }
        let vendor = (desc[kDADiskDescriptionDeviceVendorKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return Drive(
            bsdName: bsd,
            name: desc[kDADiskDescriptionVolumeNameKey as String] as? String ?? bsd,
            size: (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0,
            model: [vendor, model].filter { !$0.isEmpty }.joined(separator: " "),
            connection: desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "",
            isInternal: desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? false,
            state: state,
            freeBytes: free)
    }

    // MARK: Actions

    func mount(_ drive: Drive, readOnly: Bool) {
        perform(drive, verb: "mount") { disk, callback, context in
            if readOnly {
                var args: [Unmanaged<CFString>?] = [Unmanaged.passUnretained("rdonly" as CFString), nil]
                args.withUnsafeMutableBufferPointer { buf in
                    DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), callback, context, buf.baseAddress)
                }
            } else {
                DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), callback, context)
            }
        }
    }

    func unmount(_ drive: Drive) {
        handled.insert(drive.id)
        perform(drive, verb: "unmount") { disk, callback, context in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), callback, context)
        }
    }

    func remount(_ drive: Drive, readOnly: Bool) {
        perform(drive, verb: "unmount") { disk, callback, context in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), callback, context)
        } then: { [weak self] in
            self?.mount(drive, readOnly: readOnly)
        }
    }

    @Published var info: String?

    /// Unmounts, runs `fsck_fskit -y` (the extension runs ntfsfix in its virtual
    /// machine), then mounts again. USB disks are owned by root, so when the plain
    /// run is refused it is repeated through the macOS administrator prompt.
    func repair(_ drive: Drive) {
        let run = { [weak self] in
            guard let self else { return }
            busy.insert(drive.id)
            Task.detached {
                let device = "/dev/" + drive.bsdName
                var (status, output) = Self.shell("/sbin/fsck_fskit", ["-t", "ntfsb", "-y", device])
                if status == 13 || output.contains("Permission denied") {
                    (status, output) = await MainActor.run { Self.shellAsAdmin("/sbin/fsck_fskit -t ntfsb -y \(device) 2>&1") }
                }
                let ok = status == 0
                let summary = output.split(separator: "\n").last(where: { !$0.isEmpty }).map(String.init) ?? ""
                await MainActor.run {
                    self.busy.remove(drive.id)
                    if ok {
                        self.info = "\(drive.name) was repaired. Windows will run a disk check the next time it starts."
                    } else {
                        self.lastError = "Repair of \(drive.name) failed: \(summary.isEmpty ? "exit \(status)" : summary)"
                    }
                    self.refresh()
                    self.mount(drive, readOnly: false)
                }
            }
        }
        handled.insert(drive.id)
        if drive.isMounted {
            perform(drive, verb: "unmount") { disk, callback, context in
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), callback, context)
            } then: { run() }
        } else {
            run()
        }
    }

    nonisolated private static func shell(_ tool: String, _ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "couldn't start \(tool)") }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    /// Runs a command with administrator rights; macOS shows its own password prompt.
    private static func shellAsAdmin(_ command: String) -> (Int32, String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"NTFS Bridge needs your permission to repair the drive.\""
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            return (Int32(error[NSAppleScript.errorNumber] as? Int ?? 1), error[NSAppleScript.errorMessage] as? String ?? "cancelled")
        }
        return (0, result?.stringValue ?? "")
    }

    /// Attaches a disk image (raw .img or .dmg) without letting macOS mount it,
    /// then mounts its NTFS partitions through NTFS Bridge.
    func attachImage(_ url: URL) {
        info = nil
        lastError = nil
        Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/hdiutil")
            var args = ["attach", "-nomount", "-plist"]
            if ["img", "raw", "bin", "ntfs"].contains(url.pathExtension.lowercased()) {
                args += ["-imagekey", "diskimage-class=CRawDiskImage"]
            }
            process.arguments = args + [url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            let devices = (plist?["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
            await MainActor.run {
                guard process.terminationStatus == 0, let whole = devices.first else {
                    self.lastError = "Couldn't attach \(url.lastPathComponent)."
                    return
                }
                self.refresh()
                let base = (whole as NSString).lastPathComponent
                let ntfs = self.drives.filter { $0.bsdName == base || $0.bsdName.hasPrefix(base + "s") }
                if ntfs.isEmpty {
                    self.lastError = "\(url.lastPathComponent) has no NTFS partition."
                }
                for drive in ntfs where !drive.isMounted && !self.busy.contains(drive.id) {
                    self.handled.insert(drive.id)
                    self.mount(drive, readOnly: false)
                }
            }
        }
    }

    func reveal(_ drive: Drive) {
        if case .mounted(let path, _, _) = drive.state { NSWorkspace.shared.open(path) }
    }

    /// Runs one Disk Arbitration request, tracking the drive as busy until it answers.
    private func perform(_ drive: Drive, verb: String,
                         _ request: (DADisk, DADiskMountCallback, UnsafeMutableRawPointer) -> Void,
                         then next: (() -> Void)? = nil) {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, drive.bsdName) else { return }
        busy.insert(drive.id)
        lastError = nil
        let completion = Completion { [weak self] dissenter in
            guard let self else { return }
            busy.remove(drive.id)
            refresh()
            // Two mount requests can race (auto take-over and Mount Image); the loser's
            // refusal is moot once NTFS Bridge has the drive mounted.
            let nowMounted = drives.first { $0.id == drive.id }.map { d -> Bool in
                if case .mounted(_, .bridge, _) = d.state { return true } else { return false }
            } ?? false
            if let dissenter, !(verb == "mount" && nowMounted) {
                let status = DADissenterGetStatus(dissenter)
                let reason = DADissenterGetStatusString(dissenter) as String?
                lastError = "Couldn't \(verb) \(drive.name): \(reason ?? Self.describe(status))"
            } else {
                next?()
            }
            refresh()
        }
        let callback: DADiskMountCallback = { _, dissenter, context in
            let completion = Unmanaged<Completion>.fromOpaque(context!).takeRetainedValue()
            MainActor.assumeIsolated { completion.run(dissenter) }
        }
        request(disk, callback, Unmanaged.passRetained(completion).toOpaque())
    }

    private static func describe(_ status: DAReturn) -> String {
        switch Int(status) {
        case kDAReturnBusy: "it is in use. Close any files or apps using it and try again."
        case kDAReturnNotPermitted, kDAReturnNotPrivileged: "macOS did not allow it."
        case kDAReturnUnsupported: "no enabled file system extension accepted it."
        default: String(format: "error 0x%08x", status)
        }
    }
}

private final class Completion {
    let run: (DADissenter?) -> Void
    init(_ run: @escaping (DADissenter?) -> Void) { self.run = run }
}
