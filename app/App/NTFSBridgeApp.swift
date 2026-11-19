import ServiceManagement
import UniformTypeIdentifiers
import SwiftUI

/// Keeps the app alive in the menu bar after its window closes, so it can take over
/// drives as they are plugged in.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Disk images dropped on the app icon or opened with it are mounted.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.isFileURL { DriveStore.shared.attachImage(url) }
        }
    }
}

@main
struct NTFSBridgeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var drives = DriveStore.shared
    @StateObject private var module = ExtensionStatus()

    var body: some Scene {
        Window("NTFS Bridge", id: "main") {
            MainView()
                .environmentObject(drives)
                .environmentObject(module)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 760, height: 500)
        .windowToolbarStyle(.unified)
        .commands { DriveCommands(store: drives) }

        MenuBarExtra("NTFS Bridge", systemImage: "externaldrive.connected.to.line.below") {
            MenuBarContent().environmentObject(drives)
        }

        Settings {
            SettingsView().environmentObject(drives)
        }
    }
}

/// A "Drives" menu in the menu bar with the same actions as each drive card.
struct DriveCommands: Commands {
    @ObservedObject var store: DriveStore

    var body: some Commands {
        CommandMenu("Drives") {
            Button("Mount Image…") { chooseImage(into: store) }.keyboardShortcut("o")
            Divider()
            ForEach(store.drives) { drive in
                Menu(drive.name) {
                    if drive.isMounted {
                        Button("Open in Finder") { store.reveal(drive) }
                        Button("Unmount") { store.unmount(drive) }
                    } else {
                        Button("Mount") { store.mount(drive, readOnly: false) }
                        Button("Mount Read-Only") { store.mount(drive, readOnly: true) }
                    }
                    Button("Repair…") { store.repair(drive) }
                }
            }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var store: DriveStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.drives.isEmpty {
            Text("No NTFS drives connected")
        }
        ForEach(store.drives) { drive in
            Menu(drive.name) {
                switch drive.state {
                case .unmounted:
                    Button("Mount") { store.mount(drive, readOnly: false) }
                    Button("Mount Read-Only") { store.mount(drive, readOnly: true) }
                case .mounted(_, let driver, _):
                    Button("Open in Finder") { store.reveal(drive) }
                    if driver != .bridge {
                        Button("Remount with NTFS Bridge") { store.remount(drive, readOnly: false) }
                    }
                    Button("Unmount") { store.unmount(drive) }
                }
            }
        }
        Divider()
        Button("Mount Image…") { chooseImage(into: store) }
        Toggle("Mount NTFS Drives Automatically", isOn: $store.autoTakeOver)
        Button("Open NTFS Bridge…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit NTFS Bridge") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: DriveStore
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Mount NTFS drives automatically", isOn: $store.autoTakeOver)
                Text("When an NTFS drive is plugged in, NTFS Bridge mounts it read & write. If another driver mounted it first, NTFS Bridge remounts it. Drives you unmount stay unmounted until you plug them in again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("NTFS Bridge runs in the menu bar so drives are taken over as soon as they connect.")
                    .font(.caption).foregroundStyle(.secondary)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}

struct MainView: View {
    @EnvironmentObject private var store: DriveStore
    @EnvironmentObject private var module: ExtensionStatus
    @State private var showingHelp = false

    var body: some View {
        VStack(spacing: 0) {
            if module.state == .disabled || module.state == .missing {
                SetupBanner()
            }
            if store.drives.isEmpty {
                EmptyDrives()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.drives) { DriveCard(drive: $0) }
                    }
                    .padding(16)
                }
            }
            if let error = store.lastError {
                ErrorStrip(message: error) { store.lastError = nil }
            }
            if let info = store.info {
                InfoStrip(message: info) { store.info = nil }
            }
            Divider()
            StatusBar()
        }
        .background(.background)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.refresh(); module.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Rescan connected drives")
                Button { chooseImage(into: store) } label: { Label("Mount Image…", systemImage: "doc.badge.plus") }
                    .help("Mount an NTFS disk image (.img, .dmg)")
                Button { module.openSettings() } label: { Label("Extension Settings", systemImage: "puzzlepiece.extension") }
                    .help("Open Login Items & Extensions in System Settings")
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .help("Automatic mounting and login options")
                Button { showingHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }
            }
        }
        .sheet(isPresented: $showingHelp) { HelpSheet() }
        .onAppear { module.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            module.refresh()
            store.refresh()
        }
    }
}

// MARK: Drive card

@MainActor func chooseImage(into store: DriveStore) {
    let panel = NSOpenPanel()
    panel.title = "Mount Disk Image"
    panel.allowedContentTypes = [.diskImage, .data]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        store.attachImage(url)
    }
}

struct DriveCard: View {
    @EnvironmentObject private var store: DriveStore
    let drive: Drive

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DriveGlyph(drive: drive)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(drive.name).font(.headline)
                    StateBadge(drive: drive)
                }
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                if let note = drive.note {
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420, alignment: .leading)
                }
                if let used = usedFraction {
                    ProgressView(value: used)
                        .progressViewStyle(.linear)
                        .tint(used > 0.9 ? .orange : .accentColor)
                        .frame(maxWidth: 320)
                }
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: drive.size, countStyle: .file)
        var parts = [size, "NTFS"]
        if !drive.connection.isEmpty { parts.append(drive.connection) }
        if !drive.model.isEmpty { parts.append(drive.model) }
        if let free = drive.freeBytes {
            parts.append("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
        }
        return parts.joined(separator: " · ")
    }

    private var usedFraction: Double? {
        guard let free = drive.freeBytes, drive.size > 0 else { return nil }
        return min(1, max(0, 1 - Double(free) / Double(drive.size)))
    }

    @ViewBuilder private var actions: some View {
        if store.busy.contains(drive.id) {
            ProgressView().controlSize(.small).frame(width: 110)
        } else {
            switch drive.state {
            case .unmounted:
                Button("Mount") { store.mount(drive, readOnly: false) }
                    .buttonStyle(.borderedProminent)
                Menu {
                    Button("Mount Read-Only") { store.mount(drive, readOnly: true) }
                    Divider()
                    Button("Repair…") { store.repair(drive) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
            case .mounted(_, let driver, let readOnly):
                Button("Open") { store.reveal(drive) }
                Menu {
                    if driver == .bridge {
                        Button(readOnly ? "Remount Read-Write" : "Remount Read-Only") {
                            store.remount(drive, readOnly: !readOnly)
                        }
                    } else {
                        Button("Remount with NTFS Bridge") { store.remount(drive, readOnly: false) }
                    }
                    Divider()
                    Button("Repair…") { store.repair(drive) }
                    Button("Unmount") { store.unmount(drive) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }
}

struct DriveGlyph: View {
    let drive: Drive

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: drive.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.linearGradient(colors: [Color(red: 0.12, green: 0.45, blue: 0.75),
                                                          Color(red: 0.10, green: 0.68, blue: 0.70)],
                                                 startPoint: .top, endPoint: .bottom))
                .frame(width: 46, height: 46)
            Circle().fill(dot).frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(.background, lineWidth: 2))
        }
    }

    private var dot: Color {
        switch drive.state {
        case .unmounted: .secondary
        case .mounted(_, let driver, let readOnly): driver != .bridge ? .orange : readOnly ? .yellow : .green
        }
    }
}

struct StateBadge: View {
    let drive: Drive

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    private var text: String {
        switch drive.state {
        case .unmounted: "Not mounted"
        case .mounted(_, let driver, let readOnly):
            driver == .bridge ? (readOnly ? "Read-only" : "Read & write") : "Mounted by \(driver.label)"
        }
    }

    private var color: Color {
        switch drive.state {
        case .unmounted: .secondary
        case .mounted(_, let driver, let readOnly): driver != .bridge ? .orange : readOnly ? .yellow : .green
        }
    }
}

// MARK: Banners and bars

struct SetupBanner: View {
    @EnvironmentObject private var module: ExtensionStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Turn on the NTFS Bridge extension").font(.headline)
                Text("System Settings › General › Login Items & Extensions › switch the view to **By Category** › ⓘ next to File System Extensions › turn on NTFS Bridge.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings") { module.openSettings() }.buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.orange.opacity(0.10))
    }
}

struct ErrorStrip: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.callout)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }
}

struct InfoStrip: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.callout)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }
}

struct StatusBar: View {
    @EnvironmentObject private var module: ExtensionStatus
    @EnvironmentObject private var store: DriveStore

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.drives.count) NTFS \(store.drives.count == 1 ? "drive" : "drives")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var color: Color {
        switch module.state {
        case .enabled: .green
        case .checking: .secondary
        case .disabled, .missing: .orange
        }
    }

    private var title: String {
        switch module.state {
        case .enabled: "File system extension is on"
        case .checking: "Checking the file system extension…"
        case .disabled: "File system extension is off"
        case .missing: "File system extension isn't registered"
        }
    }

    private var detail: String {
        switch module.state {
        case .missing: "Move NTFS Bridge to the Applications folder and open it once."
        default: "Linux ntfs3 driver in a lightweight virtual machine · read & write"
        }
    }
}

struct EmptyDrives: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text("No NTFS drives connected").font(.title3.weight(.semibold))
            Text("Plug in a Windows-formatted drive and it will appear here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("NTFS Bridge").font(.title2.bold())
                    Text("Read and write NTFS drives in Finder.").foregroundStyle(.secondary)
                }
            }
            Divider()
            Label("Each drive is served by the Linux ntfs3 driver running in a small virtual machine.", systemImage: "cpu")
            Label("If Windows didn't shut down cleanly, the drive mounts read-only to protect your files. Run a disk check in Windows, then remount.", systemImage: "lock.shield")
            Label("Always unmount or eject a drive before unplugging it.", systemImage: "eject")
            Label("If another NTFS app is installed, turn its extension off so NTFS Bridge is used.", systemImage: "puzzlepiece.extension")
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 460)
    }
}
