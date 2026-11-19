import AppKit
import FSKit

/// Whether macOS will let the NTFS Bridge file system module run.
@MainActor
final class ExtensionStatus: ObservableObject {
    enum State { case checking, enabled, disabled, missing }

    @Published private(set) var state: State = .checking
    static let moduleID = "com.ravi.NTFSBridge.FS"

    func refresh() {
        FSClient.shared.fetchInstalledExtensions { modules, _ in
            let module = modules?.first { $0.bundleIdentifier == Self.moduleID }
            let next: State = module.map { $0.isEnabled ? .enabled : .disabled } ?? .missing
            Task { @MainActor in self.state = next }
        }
    }

    /// Settings › General › Login Items & Extensions. The "By App" switch is broken on
    /// macOS 27.0.1; the "By Category" › File System Extensions list works.
    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
