import UIKit

/// Settings > Debug Log: every entry, newest first, with a filter for problems only.
final class DebugLogViewController: UITableViewController {

    private let filter = UISegmentedControl(items: ["All", "Problems"])
    private var rows: [DebugLog.Entry] = []

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Debug Log"
        filter.selectedSegmentIndex = DebugLog.shared.problemCount > 0 ? 1 : 0
        filter.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        navigationItem.titleView = filter

        let share = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareLog(_:)))
        let clear = UIBarButtonItem(barButtonSystemItem: .trash, target: self, action: #selector(confirmClear))
        navigationItem.rightBarButtonItems = [share, clear]

        NotificationCenter.default.addObserver(
            self, selector: #selector(logChanged), name: .debugLogDidChange, object: nil
        )
        reload()
    }

    @objc private func logChanged() {
        reload()
    }

    private func reload() {
        let all = DebugLog.shared.entries.reversed()
        rows = filter.selectedSegmentIndex == 1 ? all.filter { $0.level != .info } : Array(all)
        tableView.reloadData()
    }

    @objc private func shareLog(_ sender: UIBarButtonItem) {
        let header = "\(AppInfo.name) debug log, \(AppInfo.version)\n\(DeviceInfo.summary)\n\n"
        let text = header + DebugLog.shared.text(onlyProblems: filter.selectedSegmentIndex == 1)
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = sender
        present(sheet, animated: true)
    }

    @objc private func confirmClear() {
        let alert = UIAlertController(title: "Clear the debug log?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            DebugLog.shared.clear()
        })
        present(alert, animated: true)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, rows.count)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Kept on this phone only, up to the last 500 entries. Tap an entry for its details. "
            + "Share sends the log as plain text, for example to paste into a chat."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        guard indexPath.row < rows.count else {
            content.text = filter.selectedSegmentIndex == 1 ? "No problems recorded" : "Nothing recorded yet"
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }

        let entry = rows[indexPath.row]
        content.text = entry.message
        content.textProperties.numberOfLines = 3
        var meta = "\(Self.time.string(from: entry.date)) · \(entry.category)"
        if entry.count > 1 {
            meta += " · ×\(entry.count)"
        }
        content.secondaryText = meta
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = Self.icon(for: entry.level)
        content.imageProperties.tintColor = Self.color(for: entry.level)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < rows.count else { return }
        navigationController?.pushViewController(DebugLogEntryViewController(entry: rows[indexPath.row]), animated: true)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func icon(for level: DebugLog.Entry.Level) -> UIImage? {
        switch level {
        case .info: return UIImage(systemName: "info.circle")
        case .warning: return UIImage(systemName: "exclamationmark.triangle.fill")
        case .error: return UIImage(systemName: "xmark.octagon.fill")
        }
    }

    static func color(for level: DebugLog.Entry.Level) -> UIColor {
        switch level {
        case .info: return .secondaryLabel
        case .warning: return .systemOrange
        case .error: return .systemRed
        }
    }
}

/// One entry in full, selectable so any part can be copied.
final class DebugLogEntryViewController: UIViewController {

    private let entry: DebugLog.Entry
    private let textView = UITextView()

    init(entry: DebugLog.Entry) {
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = entry.category
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Copy", style: .plain, target: self, action: #selector(copyEntry)
        )

        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        textView.text = fullText
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
    }

    private var fullText: String {
        var lines = [
            "Level:    \(entry.level.rawValue.capitalized)",
            "Time:     \(DebugLog.timestamp.string(from: entry.date))",
            "Category: \(entry.category)",
        ]
        if entry.count > 1 {
            lines.append("Times:    \(entry.count) (time shown is the latest)")
        }
        lines += ["", entry.message]
        if let details = entry.details, !details.isEmpty {
            lines += ["", "Details:", details]
        }
        return lines.joined(separator: "\n")
    }

    @objc private func copyEntry() {
        UIPasteboard.general.string = fullText
        showAlert(title: "Copied", message: nil)
    }
}
