import Foundation

/// Why a drive mounted the way it did, passed from the file system extension to
/// the app through their shared app-group container.
enum MountNotes {
    static let group = "YBR22TF7H3.com.ravi.NTFSBridge"

    struct Entry: Codable {
        var readOnly: Bool
        var note: String
        var date: Date
    }

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appending(path: "mount-notes.json")
    }

    static func read() -> [String: Entry] {
        guard let file, let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    static func publish(bsdName: String, readOnly: Bool, note: String) {
        guard let file else { return }
        var all = read()
        all[bsdName] = Entry(readOnly: readOnly, note: note, date: Date())
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: file, options: .atomic)
    }
}
