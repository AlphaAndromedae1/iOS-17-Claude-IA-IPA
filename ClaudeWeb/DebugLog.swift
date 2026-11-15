import Foundation

extension Notification.Name {
    static let debugLogDidChange = Notification.Name("DebugLogDidChange")
}

/// A record of what happened, for Settings > Debug Log: page loads, load errors, the web page
/// stopping, JavaScript errors from claude.ai, what the iOS 17 style fix did, downloads.
/// It stays on the phone (the app's Caches folder) and keeps the last 500 entries, so it survives
/// closing the app. Each entry also goes to the system log, which Console on a Mac can show.
@MainActor
final class DebugLog: NSObject {

    struct Entry: Codable {
        enum Level: String, Codable {
            case info, warning, error
        }

        let id: UUID
        var date: Date
        let level: Level
        let category: String
        let message: String
        var details: String?
        /// How many times it happened; repeats are counted instead of listed again.
        var count: Int
    }

    static let shared = DebugLog()

    private static let maxEntries = 500

    private(set) var entries: [Entry] = []
    private let fileURL: URL

    private override init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = caches.appendingPathComponent("DebugLog.json")
        super.init()
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    var problemCount: Int {
        entries.filter { $0.level != .info }.count
    }

    func info(_ category: String, _ message: String, details: String? = nil) {
        add(.info, category, message, details: details)
    }

    func warning(_ category: String, _ message: String, details: String? = nil) {
        add(.warning, category, message, details: details)
    }

    func error(_ category: String, _ message: String, details: String? = nil) {
        add(.error, category, message, details: details)
    }

    func add(_ level: Entry.Level, _ category: String, _ message: String, details: String? = nil) {
        let message = String(message.prefix(500))
        let details = details.map { String($0.prefix(8000)) }

        if let index = entries.suffix(20).lastIndex(where: {
            $0.level == level && $0.category == category && $0.message == message
        }) {
            entries[index].count += 1
            entries[index].date = Date()
            if let details {
                entries[index].details = details
            }
        } else {
            entries.append(Entry(
                id: UUID(), date: Date(), level: level, category: category,
                message: message, details: details, count: 1
            ))
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
        }

        NSLog("[ClaudeWeb] %@ · %@ · %@", level.rawValue, category, message)
        NotificationCenter.default.post(name: .debugLogDidChange, object: self)
        scheduleSave()
    }

    func clear() {
        entries = []
        NotificationCenter.default.post(name: .debugLogDidChange, object: self)
        save()
    }

    /// Plain text, newest last, for copying or sharing.
    func text(onlyProblems: Bool = false, limit: Int? = nil) -> String {
        var selected = onlyProblems ? entries.filter { $0.level != .info } : entries
        if let limit, selected.count > limit {
            selected = Array(selected.suffix(limit))
        }
        return selected.map(Self.describe).joined(separator: "\n\n")
    }

    static func describe(_ entry: Entry) -> String {
        var line = "\(timestamp.string(from: entry.date))  \(entry.level.rawValue.uppercased())  \(entry.category): \(entry.message)"
        if entry.count > 1 {
            line += "  (×\(entry.count))"
        }
        if let details = entry.details, !details.isEmpty {
            line += "\n" + details.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    " + $0 }.joined(separator: "\n")
        }
        return line
    }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    // MARK: - Saving

    private func scheduleSave() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(save), object: nil)
        perform(#selector(save), with: nil, afterDelay: 1)
    }

    @objc func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
