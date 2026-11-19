import FSKit
import Foundation

/// Serves the FSKit-provided partition to the guest's NBD client.
final class DeviceBackend: BlockBackend {
    private let device: FSBlockDeviceResource
    let size: UInt64
    let blockSize: UInt32
    let readOnly: Bool

    init(device: FSBlockDeviceResource, readOnly: Bool) {
        self.device = device
        blockSize = UInt32(device.blockSize)
        size = device.blockCount * device.blockSize
        self.readOnly = readOnly
    }

    /// Device read statistics, logged on unmount to separate device time from
    /// pipeline overhead.
    private(set) var readBytes = 0
    private(set) var readCalls = 0
    private(set) var readTime: Duration = .zero

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws {
        let start = ContinuousClock.now
        defer { readTime += ContinuousClock.now - start; readCalls += 1; readBytes += buffer.count }
        var done = 0
        while done < buffer.count {
            let span = UnsafeMutableRawBufferPointer(rebasing: buffer[done...])
            let n = try device.read(into: span, startingAt: off_t(offset) + off_t(done), length: span.count)
            guard n > 0 else { throw fs_errorForPOSIXError(EIO) }
            done += n
        }
    }

    func write(from buffer: UnsafeRawBufferPointer, at offset: UInt64) throws {
        var done = 0
        while done < buffer.count {
            let span = UnsafeRawBufferPointer(rebasing: buffer[done...])
            let n = try device.write(from: span, startingAt: off_t(offset) + off_t(done), length: span.count)
            guard n > 0 else { throw fs_errorForPOSIXError(EIO) }
            done += n
        }
    }

    /// Writes go straight to the device through `write(from:startingAt:length:)`, which
    /// bypasses the kernel buffer cache. `metadataFlush()` only flushes that cache
    /// (data from `delayedMetadataWrite`), so it has nothing to do here and fails with
    /// EIO. The drive's own write cache is flushed by the storage stack on eject.
    func flush() throws {}
}
