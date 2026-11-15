import Foundation

/// The servers the page has contacted since the app started, for the Privacy Report.
/// Only host names and counts are kept, only in memory, and nothing is sent anywhere.
@MainActor
final class NetworkLog {

    struct Entry {
        let host: String
        var requests = 0
        var blocked = 0
        var kinds: Set<String> = []
    }

    enum Group: CaseIterable {
        case otherCompanies, anthropic, essential

        var title: String {
            switch self {
            case .otherCompanies: return "Other companies"
            case .anthropic: return "Anthropic"
            case .essential: return "Needed for Claude to work"
            }
        }

        static func of(_ host: String) -> Group {
            if TrackerLists.isEssential(host) { return .essential }
            if LinkRouter.isAppHost(host) { return .anthropic }
            return .otherCompanies
        }
    }

    private static let maxHosts = 500

    private(set) var entries: [String: Entry] = [:]

    /// Called after each change, while the Privacy Report is open.
    var onChange: (() -> Void)?

    /// A batch posted by `PageScripts.networkObserver`: `{ host: { n: count, t: [kinds] } }`.
    func recordBatch(_ body: Any) {
        guard let batch = body as? [String: Any] else { return }
        for (host, value) in batch {
            guard let item = value as? [String: Any] else { continue }
            let count = (item["n"] as? NSNumber)?.intValue ?? 1
            let kinds = item["t"] as? [String] ?? []
            add(host: host, requests: count, kinds: kinds)
        }
        onChange?()
    }

    func recordNavigation(to url: URL, mainFrame: Bool) {
        add(host: url.host, requests: 1, kinds: [mainFrame ? "page" : "frame"])
        onChange?()
    }

    func recordBlocked(_ url: URL?) {
        add(host: url?.host, blocked: 1)
        onChange?()
    }

    func clear() {
        entries = [:]
        onChange?()
    }

    func blockedEntries() -> [Entry] {
        entries.values.filter { $0.blocked > 0 }
            .sorted { $0.blocked != $1.blocked ? $0.blocked > $1.blocked : $0.host < $1.host }
    }

    func contactedEntries(in group: Group) -> [Entry] {
        entries.values.filter { $0.requests > 0 && Group.of($0.host) == group }
            .sorted { $0.requests != $1.requests ? $0.requests > $1.requests : $0.host < $1.host }
    }

    /// Plain text to paste somewhere: host names and counts only.
    func reportText(blockList: BlockList) -> String {
        var lines = [
            "\(AppInfo.name) privacy report, \(AppInfo.version)",
            "Tracker blocking: \(blockList.isEnabled ? "on" : "off"), \(blockList.hosts.count) addresses on the list",
            "",
        ]
        let blocked = blockedEntries()
        if !blocked.isEmpty {
            lines.append("Blocked:")
            lines += blocked.map { "  \($0.host)  \($0.blocked) blocked" }
            lines.append("")
        }
        for group in Group.allCases {
            let contacted = contactedEntries(in: group)
            guard !contacted.isEmpty else { continue }
            lines.append("\(group.title):")
            lines += contacted.map { entry in
                "  \(entry.host)  \(entry.requests) requests (\(entry.kinds.sorted().joined(separator: ", ")))"
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func add(host rawHost: String?, requests: Int = 0, blocked: Int = 0, kinds: [String] = []) {
        guard let host = rawHost?.lowercased(), !host.isEmpty, host.count <= 253 else { return }
        if entries[host] == nil {
            guard entries.count < Self.maxHosts else { return }
            entries[host] = Entry(host: host)
        }
        entries[host]?.requests += max(0, requests)
        entries[host]?.blocked += max(0, blocked)
        entries[host]?.kinds.formUnion(kinds.prefix(10).map { String($0.prefix(24)) })
    }
}
