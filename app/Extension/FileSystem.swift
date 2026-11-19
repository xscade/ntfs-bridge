import FSKit
import Foundation
import os

let log = Logger(subsystem: "com.ravi.NTFSBridge.FS", category: "fs")

@main
struct NTFSBridgeExtension: UnaryFileSystemExtension {
    let fileSystem = NTFSFileSystem()
}

/// Recognizes NTFS partitions and hands each one to an `NTFSVolume`.
final class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, FSManageableResourceMaintenanceOperations {
    private var loadedDevice: FSBlockDeviceResource?

    /// Disk Arbitration runs a quick check (`-q`) before every mount: that only
    /// validates the boot sector, since ntfs3 and ntfs-3g refuse unsafe volumes at
    /// mount time anyway. A full check (`-n`, Disk Utility First Aid verify) runs
    /// `ntfsfix -n` in the guest; a repair (`-y`, `diskutil repairVolume`) runs
    /// `ntfsfix`, which fixes $MFTMirr and resets the journal.
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        guard let device = loadedDevice else { throw fs_errorForPOSIXError(ENODEV) }
        let flags = Set(options.taskOptions.flatMap { $0.hasPrefix("-") && !$0.hasPrefix("--") ? $0.dropFirst().map(String.init) : [$0] })
        let repair = flags.contains("y") || flags.contains("--repair")
        let quick = flags.contains("q") && !repair
        log.info("check options=\(options.taskOptions, privacy: .public) repair=\(repair) quick=\(quick)")
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                _ = try NTFSBootSector(device: device)
                if quick {
                    task.logMessage("NTFS boot sector is valid; the journal and dirty flag are checked at mount.")
                } else {
                    let (code, output) = try await Self.runNTFSFix(device: device, repair: repair)
                    task.logMessage(output)
                    if code != 0 { throw fs_errorForPOSIXError(repair ? EIO : EFTYPE) }
                }
                progress.completedUnitCount = 1
                task.didComplete(error: nil)
            } catch {
                log.error("check failed: \(String(describing: error), privacy: .public)")
                task.didComplete(error: error)
            }
        }
        return progress
    }

    private static func runNTFSFix(device: FSBlockDeviceResource, repair: Bool) async throws -> (Int32, String) {
        let resources = Bundle(for: NTFSFileSystem.self)
        guard let kernel = resources.url(forResource: "Image", withExtension: nil),
              let initrd = resources.url(forResource: "initrd", withExtension: "gz") else {
            throw fs_errorForPOSIXError(ENOENT)
        }
        let backend = DeviceBackend(device: device, readOnly: !repair || !device.isWritable)
        let console = FileManager.default.temporaryDirectory.appending(path: "ntfsbridge-check.log")
        let vm = try GuestVM(kernel: kernel, initrd: initrd, disk: backend, consoleLog: console)
        let client = try await vm.start()
        defer { Task { await vm.forceStop() } }
        let result = try await client.check(repair: repair)
        try? await client.unmount()
        _ = await vm.waitUntilStopped(timeout: .seconds(15))
        return (result.exitCode, result.output)
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw fs_errorForPOSIXError(ENOTSUP)
    }
    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, Error?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource,
              let boot = try? NTFSBootSector(device: device) else {
            replyHandler(.notRecognized, nil)
            return
        }
        replyHandler(.usable(name: boot.label ?? "NTFS", containerID: FSContainerIdentifier(uuid: boot.uuid)), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler: @escaping (FSVolume?, Error?) -> Void) {
        do {
            guard let device = resource as? FSBlockDeviceResource else {
                throw fs_errorForPOSIXError(EINVAL)
            }
            let boot = try NTFSBootSector(device: device)
            let readOnly = !device.isWritable || options.requestsReadOnly
            let volume = NTFSVolume(device: device, uuid: boot.uuid, label: boot.label, readOnly: readOnly)
            loadedDevice = device
            containerStatus = .ready
            log.info("loaded \(device.bsdName, privacy: .public) readOnly=\(readOnly)")
            replyHandler(volume, nil)
        } catch {
            log.error("load failed: \(String(describing: error), privacy: .public)")
            replyHandler(nil, error)
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler: @escaping (Error?) -> Void) {
        replyHandler(nil)
    }
}

extension FSTaskOptions {
    var requestsReadOnly: Bool {
        taskOptions.contains { option in
            option.split(separator: ",").contains { $0 == "rdonly" || $0 == "ro" }
        } || taskOptions.contains("-r")
    }
}

/// The fields of the NTFS boot sector this extension needs.
struct NTFSBootSector {
    let serial: UInt64

    init(device: FSBlockDeviceResource) throws {
        let length = max(Int(device.blockSize), 512)
        var sector = [UInt8](repeating: 0, count: length)
        try sector.withUnsafeMutableBytes { buf in
            _ = try device.read(into: buf, startingAt: 0, length: length)
        }
        guard sector[3..<11].elementsEqual("NTFS    ".utf8), sector[510] == 0x55, sector[511] == 0xAA else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        serial = sector[0x48..<0x50].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        label = Self.readLabel(device: device, boot: sector)
    }

    /// The volume label, from the $VOLUME_NAME attribute of MFT record 3 ($Volume).
    let label: String?

    private static func readLabel(device: FSBlockDeviceResource, boot: [UInt8]) -> String? {
        func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }
        func shift(_ raw: UInt8) -> Int? { Int8(bitPattern: raw) < 0 ? 1 << Int(-Int8(bitPattern: raw)) : nil }

        let sectorSize = u16(boot, 0x0B)
        let clusterSize = shift(boot[0x0D]) ?? Int(boot[0x0D]) * sectorSize
        let recordSize = shift(boot[0x40]) ?? Int(boot[0x40]) * clusterSize
        let mftCluster = boot[0x30..<0x38].reversed().reduce(0) { $0 << 8 | Int($1) }
        guard sectorSize >= 256, clusterSize > 0, (1024...65536).contains(recordSize) else { return nil }

        let start = mftCluster * clusterSize + 3 * recordSize
        let block = max(Int(device.blockSize), 512)
        let alignedStart = start / block * block
        let length = (start + recordSize - alignedStart + block - 1) / block * block
        var raw = [UInt8](repeating: 0, count: length)
        guard (try? raw.withUnsafeMutableBytes({ try device.read(into: $0, startingAt: off_t(alignedStart), length: length) })) == length
        else { return nil }
        var rec = Array(raw[(start - alignedStart)..<(start - alignedStart + recordSize)])
        guard rec[0..<4].elementsEqual("FILE".utf8) else { return nil }

        // Undo the update-sequence fixups at the end of each sector.
        let usa = u16(rec, 4), usaCount = u16(rec, 6)
        for i in 1..<max(usaCount, 1) where i * sectorSize <= recordSize {
            rec[i * sectorSize - 2] = rec[usa + 2 * i]
            rec[i * sectorSize - 1] = rec[usa + 2 * i + 1]
        }

        var offset = u16(rec, 0x14)
        while offset + 24 <= recordSize {
            let type = u32(rec, offset), length = u32(rec, offset + 4)
            if type == 0xFFFF_FFFF || length == 0 { break }
            if type == 0x60, rec[offset + 8] == 0 {
                let size = u32(rec, offset + 0x10), at = offset + u16(rec, offset + 0x14)
                guard at + size <= recordSize, size > 0 else { return nil }
                let units = stride(from: at, to: at + size, by: 2).map { UInt16(rec[$0]) | UInt16(rec[$0 + 1]) << 8 }
                return String(decoding: units, as: UTF16.self)
            }
            offset += length
        }
        return nil
    }

    /// A stable UUID derived from the NTFS volume serial number.
    var uuid: UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: serial.bigEndian) { bytes.replaceSubrange(8..<16, with: $0) }
        bytes[0...3] = [0x4E, 0x54, 0x46, 0x53]
        bytes[6] = 0x40 | (bytes[6] & 0x0F)
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
