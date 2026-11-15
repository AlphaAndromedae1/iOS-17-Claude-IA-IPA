import UIKit

/// Shows which servers the page has contacted this session, which requests were blocked, and
/// the block list, and lets you block or unblock any address that Claude doesn't need.
final class NetworkReportViewController: UITableViewController {

    /// Called once when the screen closes; `changed` is true if the block list was edited.
    var onFinish: ((_ changed: Bool) -> Void)?

    private enum Section: Int, CaseIterable {
        case settings, blocked, otherCompanies, anthropic, essential, blockList
    }

    private let log: NetworkLog
    private let blockList: BlockList
    private var changed = false
    private var finished = false
    /// Rows in the Block List section. Stays put while you switch entries off and on.
    private var listedHosts: [String] = []

    init(log: NetworkLog, blockList: BlockList) {
        self.log = log
        self.blockList = blockList
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Privacy Report"
        let copy = UIBarButtonItem(title: "Copy", style: .plain, target: self, action: #selector(copyReport))
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = copy
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done, target: self, action: #selector(close)
            )
        } else {
            // Opened from Settings: keep the back button.
            navigationItem.rightBarButtonItem = copy
        }
        listedHosts = Set(TrackerLists.defaultHosts).union(blockList.addedHosts).sorted()
        log.onChange = { [weak self] in self?.tableView.reloadData() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Covers Done, going back to Settings, and swiping the sheet away.
        if isMovingFromParent || (navigationController?.isBeingDismissed ?? isBeingDismissed) {
            finish()
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        log.onChange = nil
        onFinish?(changed)
    }

    @objc private func copyReport() {
        UIPasteboard.general.string = log.reportText(blockList: blockList)
        showAlert(title: "Report copied", message: "It contains server addresses and request counts only, nothing from your chats.")
    }

    // MARK: - Data

    private func rows(in section: Section) -> [NetworkLog.Entry] {
        switch section {
        case .blocked: return log.blockedEntries()
        case .otherCompanies: return log.contactedEntries(in: .otherCompanies)
        case .anthropic: return log.contactedEntries(in: .anthropic)
        case .essential: return log.contactedEntries(in: .essential)
        case .settings, .blockList: return []
        }
    }

    private func detail(for entry: NetworkLog.Entry, in section: Section) -> String {
        if section == .blocked {
            return "\(entry.blocked) blocked"
        }
        var parts = ["\(entry.requests) request" + (entry.requests == 1 ? "" : "s")]
        if !entry.kinds.isEmpty {
            parts.append(entry.kinds.sorted().joined(separator: ", "))
        }
        if let rule = blockList.coveringEntry(for: entry.host) {
            parts.append(rule == entry.host ? "on block list" : "blocked as part of \(rule)")
        }
        return parts.joined(separator: " · ")
    }

    private func setBlocked(_ host: String, _ blocked: Bool) {
        if blocked {
            blockList.block(host)
        } else {
            blockList.unblock(host)
        }
        changed = true
        tableView.reloadData()
    }

    private func blockSwitch(for host: String) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = blockList.coveringEntry(for: host) != nil
        toggle.addAction(UIAction { [weak self] action in
            guard let toggle = action.sender as? UISwitch else { return }
            self?.setBlocked(host, toggle.isOn)
        }, for: .valueChanged)
        return toggle
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection index: Int) -> Int {
        guard let section = Section(rawValue: index) else { return 0 }
        switch section {
        case .settings: return 2
        case .blocked, .otherCompanies: return max(1, rows(in: section).count)  // a placeholder when empty
        case .anthropic, .essential: return rows(in: section).count
        case .blockList: return listedHosts.count + 2
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection index: Int) -> String? {
        guard let section = Section(rawValue: index) else { return nil }
        switch section {
        case .settings: return nil
        case .blocked: return "Blocked This Session"
        case .otherCompanies: return "Other Companies"
        case .anthropic: return rows(in: section).isEmpty ? nil : "Anthropic"
        case .essential: return rows(in: section).isEmpty ? nil : "Needed for Claude to Work"
        case .blockList: return "Block List"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection index: Int) -> String? {
        guard let section = Section(rawValue: index) else { return nil }
        switch section {
        case .settings:
            return "Blocks \(blockList.hosts.count) tracking, analytics and advertising addresses. "
                + "This list only covers what the claude.ai page itself loads. It's kept in memory "
                + "while the app is open and never leaves your phone."
        case .blocked:
            return nil
        case .otherCompanies:
            return "Servers run by other companies that claude.ai contacted. Switch one on to block it. "
                + "If part of Claude stops working, switch off the last one you blocked."
        case .anthropic:
            return rows(in: section).isEmpty ? nil
                : "Anthropic's own servers. Analytics can go through these addresses too, but block one "
                + "only if you know what it's for."
        case .essential:
            return rows(in: section).isEmpty ? nil
                : "Claude's app files, artifacts, sign-in, Cloudflare's security check and payments. "
                + "These can't be blocked."
        case .blockList:
            return "Blocking an address also blocks everything under it, so segment.com covers cdn.segment.com. "
                + "Changes apply when you close this screen."
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.color = .secondaryLabel

        guard let section = Section(rawValue: indexPath.section) else { return cell }
        switch section {
        case .settings:
            if indexPath.row == 0 {
                content.text = "Block Trackers"
                let toggle = UISwitch()
                toggle.isOn = blockList.isEnabled
                toggle.addAction(UIAction { [weak self] action in
                    guard let self, let toggle = action.sender as? UISwitch else { return }
                    self.blockList.isEnabled = toggle.isOn
                    self.changed = true
                    self.tableView.reloadData()
                }, for: .valueChanged)
                cell.accessoryView = toggle
            } else {
                content.text = "Clear Activity"
                content.textProperties.color = .accent
                cell.selectionStyle = .default
            }

        case .blocked, .otherCompanies, .anthropic, .essential:
            let entries = rows(in: section)
            guard indexPath.row < entries.count else {
                content.text = section == .blocked
                    ? (blockList.isEnabled ? "Nothing blocked yet" : "Tracker blocking is off")
                    : "Nothing yet"
                content.textProperties.color = .secondaryLabel
                break
            }
            let entry = entries[indexPath.row]
            content.text = entry.host
            content.secondaryText = detail(for: entry, in: section)
            if section != .blocked && section != .essential && TrackerLists.canBlock(entry.host) {
                cell.accessoryView = blockSwitch(for: entry.host)
            }

        case .blockList:
            if indexPath.row < listedHosts.count {
                let host = listedHosts[indexPath.row]
                content.text = host
                if !TrackerLists.defaultHosts.contains(host) {
                    content.secondaryText = "Added by you"
                }
                cell.accessoryView = blockSwitch(for: host)
            } else {
                let isAddRow = indexPath.row == listedHosts.count
                content.text = isAddRow ? "Add Address…" : "Restore Default List"
                content.textProperties.color = .accent
                cell.selectionStyle = .default
            }
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = Section(rawValue: indexPath.section) else { return }

        if section == .settings && indexPath.row == 1 {
            log.clear()
        } else if section == .blockList && indexPath.row == listedHosts.count {
            askForHost()
        } else if section == .blockList && indexPath.row == listedHosts.count + 1 {
            blockList.restoreDefaults()
            listedHosts = TrackerLists.defaultHosts.sorted()
            changed = true
            tableView.reloadData()
        }
    }

    private func askForHost() {
        let alert = UIAlertController(
            title: "Block an Address",
            message: "Enter a server address such as tracker.example.com. Everything under it is blocked too.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "tracker.example.com"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Block", style: .default) { [weak self, weak alert] _ in
            self?.addHost(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }

    private func addHost(_ input: String) {
        guard let host = TrackerLists.normalizedHost(input) else {
            showAlert(title: "That isn't a server address", message: "Use a form like tracker.example.com.")
            return
        }
        guard TrackerLists.canBlock(host) else {
            showAlert(title: "Claude needs \(host)", message: "Blocking it would stop Claude, sign-in or payments from working.")
            return
        }
        blockList.block(host)
        if !listedHosts.contains(host) {
            listedHosts = (listedHosts + [host]).sorted()
        }
        changed = true
        tableView.reloadData()
    }
}
