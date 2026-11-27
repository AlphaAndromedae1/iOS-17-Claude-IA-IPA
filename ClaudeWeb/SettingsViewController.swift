import UIKit

/// Settings: app and device details, the debug log, troubleshooting, privacy and website data.
/// Opened from the shake menu, or from the error screen.
final class SettingsViewController: UITableViewController {

    /// What the screen asks the main screen to do. Actions that change the page close Settings first.
    struct Toggle {
        var isOn: () -> Bool
        var set: (Bool) -> Void
    }

    struct Actions {
        var addOnsEnabled: () -> Bool
        var diagnostics: () -> String
        var makePrivacyReport: () -> UIViewController
        var trackerBlocking: Toggle
        var styleFix: Toggle
        var loadTestPage: () -> Void
        var reloadWithoutAddOns: () -> Void
        var clearCache: () -> Void
        var signOutAndReset: () -> Void
    }

    private enum Row {
        case info(title: String, value: () -> String)
        case toggle(title: String, toggle: Toggle)
        case debugLog, copyDiagnostics, loadTestPage, reloadWithoutAddOns
        case privacyReport
        case clearCache, signOutAndReset
    }

    private struct Section {
        let title: String?
        let footer: String?
        let rows: [Row]
    }

    private let actions: Actions
    private lazy var sections: [Section] = [
        Section(title: "Claude Web", footer: nil, rows: [
            .info(title: "Version", value: { AppInfo.version.replacingOccurrences(of: "Version ", with: "") }),
            .info(title: "Device", value: { "\(DeviceInfo.model), \(DeviceInfo.memory)" }),
            .info(title: "iOS", value: { DeviceInfo.systemVersion }),
            .info(title: "Add-ons", value: { [addOnsEnabled = self.actions.addOnsEnabled] in
                addOnsEnabled() ? "On" : "Off until reopened"
            }),
        ]),
        Section(
            title: "Blocking",
            footer: "Trackers: known analytics and advertising services; Privacy Report shows what was blocked and "
                + "lets you edit the list. iOS 17 style fix: keeps claude.ai from crashing WebKit on iOS 17.3; "
                + "turn it off only to test. Changes reload the page.",
            rows: [
                .toggle(title: "Block Trackers", toggle: actions.trackerBlocking),
                .toggle(title: "iOS 17 Style Fix", toggle: actions.styleFix),
                .privacyReport,
            ]
        ),
        Section(
            title: "Debugging",
            footer: "The debug log records page loads, load errors, the page crashing and why, JavaScript errors "
                + "from claude.ai and what the iOS 17 style fix did. It stays on this phone.",
            rows: [.debugLog, .copyDiagnostics, .loadTestPage, .reloadWithoutAddOns]
        ),
        Section(
            title: "Storage",
            footer: "The cache is cleared automatically when the app's data passes "
                + CacheJanitor.format(CacheJanitor.sizeLimit) + " or hasn't been cleared for a week, when the app "
                + "opens or you come back to it. Clear Cache does the same now. Both keep you signed in. "
                + "Sign Out and Reset deletes everything claude.ai stored in this app.",
            rows: [
                .info(title: "App Data", value: { CacheJanitor.lastMeasuredSize.map(CacheJanitor.format) ?? "Measuring…" }),
                .info(title: "Last Cleared", value: {
                    CacheJanitor.lastCleaned.map {
                        DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
                    } ?? "Never"
                }),
                .toggle(title: "Clear Cache Automatically", toggle: Toggle(
                    isOn: { AppSettings.autoClearCache },
                    set: { on in
                        AppSettings.autoClearCache = on
                        DebugLog.shared.info("Settings", "Automatic cache clean-up turned \(on ? "on" : "off")")
                    }
                )),
                .clearCache,
                .signOutAndReset,
            ]
        ),
    ]

    init(actions: Actions) {
        self.actions = actions
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close)
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(logChanged), name: .debugLogDidChange, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
        CacheJanitor.measure { [weak self] _ in
            self?.tableView.reloadData()
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func logChanged() {
        tableView.reloadData()
    }

    /// Closes Settings, then runs `action` on the main screen.
    private func closeThen(_ action: @escaping () -> Void) {
        dismiss(animated: true, completion: action)
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()

        switch sections[indexPath.section].rows[indexPath.row] {
        case let .info(title, value):
            content.text = title
            content.secondaryText = value()
            cell.selectionStyle = .none
        case let .toggle(title, toggle):
            content.text = title
            let control = UISwitch()
            control.isOn = toggle.isOn()
            control.addAction(UIAction { action in
                guard let control = action.sender as? UISwitch else { return }
                toggle.set(control.isOn)
            }, for: .valueChanged)
            cell.accessoryView = control
            cell.selectionStyle = .none
        case .debugLog:
            content.text = "Debug Log"
            let problems = DebugLog.shared.problemCount
            content.secondaryText = problems == 0 ? "No problems" : "\(problems) problem" + (problems == 1 ? "" : "s")
            content.secondaryTextProperties.color = problems == 0 ? .secondaryLabel : .systemRed
            cell.accessoryType = .disclosureIndicator
        case .copyDiagnostics:
            content.text = "Copy Diagnostics"
            content.textProperties.color = .accent
        case .loadTestPage:
            content.text = "Load a Test Page"
            content.textProperties.color = .accent
        case .reloadWithoutAddOns:
            content.text = "Reload Without Add-ons"
            content.textProperties.color = .accent
        case .privacyReport:
            content.text = "Privacy Report & Block List"
            cell.accessoryType = .disclosureIndicator
        case .clearCache:
            content.text = "Clear Cache"
            content.textProperties.color = .accent
        case .signOutAndReset:
            content.text = "Sign Out and Reset…"
            content.textProperties.color = .systemRed
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        switch sections[indexPath.section].rows[indexPath.row] {
        case .info, .toggle:
            break
        case .debugLog:
            navigationController?.pushViewController(DebugLogViewController(), animated: true)
        case .copyDiagnostics:
            UIPasteboard.general.string = actions.diagnostics()
            showAlert(
                title: "Diagnostics copied",
                message: "Device, versions, the page's recent stops and the latest problems from the debug log. "
                    + "Nothing from your conversations."
            )
        case .loadTestPage:
            closeThen(actions.loadTestPage)
        case .reloadWithoutAddOns:
            closeThen(actions.reloadWithoutAddOns)
        case .privacyReport:
            navigationController?.pushViewController(actions.makePrivacyReport(), animated: true)
        case .clearCache:
            closeThen(actions.clearCache)
        case .signOutAndReset:
            confirmReset()
        }
    }

    private func confirmReset() {
        let alert = UIAlertController(
            title: "Sign out and reset?",
            message: "This deletes the cookies, cache and stored data in this app. You'll need to sign in again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.closeThen(self.actions.signOutAndReset)
        })
        present(alert, animated: true)
    }
}
