import Foundation
import Virtualization

/// A Linux microVM that owns one NTFS disk and serves it to the host over vsock.
public final class GuestVM: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    public static let agentPort: UInt32 = 7000
    public static let nbdPort: UInt32 = 7001

    private let queue = DispatchQueue(label: "ntfsbridge.vm")
    private let vm: VZVirtualMachine
    private let backend: BlockBackend
    private var stopHandler: (@Sendable (String) -> Void)?
    private var nbd: NBDServer?

    public init(kernel: URL, initrd: URL, disk: BlockBackend, consoleLog: URL?) throws {
        backend = disk
        let config = VZVirtualMachineConfiguration()
        let boot = VZLinuxBootLoader(kernelURL: kernel)
        boot.initialRamdiskURL = initrd
        boot.commandLine = "console=hvc0 loglevel=4 panic=1 rdinit=/init "
            + "ntfsb.size=\(disk.size) ntfsb.bs=\(disk.blockSize) ntfsb.ro=\(disk.readOnly ? 1 : 0)"
        config.bootLoader = boot
        config.cpuCount = 2
        config.memorySize = 768 << 20

        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        let logHandle: FileHandle
        if let consoleLog {
            FileManager.default.createFile(atPath: consoleLog.path, contents: nil)
            logHandle = try FileHandle(forWritingTo: consoleLog)
        } else {
            logHandle = FileHandle.nullDevice
        }
        console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil,
                                                              fileHandleForWriting: logHandle)
        config.serialPorts = [console]
        try config.validate()
        vm = VZVirtualMachine(configuration: config, queue: queue)
        super.init()
        queue.sync { vm.delegate = self }
    }

    /// Called once if the guest stops on its own (crash, panic, power-off).
    public func onStop(_ handler: @escaping @Sendable (String) -> Void) {
        queue.sync { stopHandler = handler }
    }

    /// Boots the guest and connects to its agent.
    public func start() async throws -> BridgeClient {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { self.vm.start { cont.resume(with: $0) } }
        }
        let disk = try await connect(port: Self.nbdPort)
        let server = NBDServer(fd: disk.fileDescriptor, backend: backend, keepAlive: disk)
        server.start()
        nbd = server
        let agent = try await connect(port: Self.agentPort)
        return BridgeClient(fd: agent.fileDescriptor, keepAlive: agent)
    }

    /// Retries while the guest boots and starts listening.
    private func connect(port: UInt32) async throws -> VZVirtioSocketConnection {
        let deadline = Date().addingTimeInterval(20)
        while true {
            do {
                return try await connectOnce(port: port)
            } catch {
                if Date() > deadline { throw BridgeError.vm("guest port \(port) did not answer: \(error)") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func connectOnce(port: UInt32) async throws -> VZVirtioSocketConnection {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.vm.state == .running,
                      let device = self.vm.socketDevices.first as? VZVirtioSocketDevice else {
                    cont.resume(throwing: BridgeError.vm("guest is not running"))
                    return
                }
                device.connect(toPort: port) { cont.resume(with: $0) }
            }
        }
    }

    /// Stops the VM immediately. Call only after a clean UNMOUNT, or to abort.
    public func forceStop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                guard self.vm.canStop else { cont.resume(); return }
                self.vm.stop { _ in cont.resume() }
            }
        }
    }

    /// Waits up to `timeout` for the guest to power itself off.
    public func waitUntilStopped(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let state = queue.sync { vm.state }
            if state == .stopped || state == .error { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        stopHandler?("guest powered off")
        stopHandler = nil
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        stopHandler?("guest stopped: \(error.localizedDescription)")
        stopHandler = nil
    }
}
