import UIKit
import WebKit

// MARK: - Colors

extension UIColor {
    /// Claude's page background (light and dark), also used for the launch screen.
    static let appBackground = UIColor(named: "Background") ?? .systemBackground
    static let accent = UIColor(named: "AccentColor") ?? .systemOrange

    /// `[r, g, b]` in 0...255, as posted by the page script.
    convenience init?(rgbComponents value: Any?) {
        guard let parts = value as? [NSNumber], parts.count >= 3 else { return nil }
        self.init(
            red: CGFloat(parts[0].doubleValue) / 255,
            green: CGFloat(parts[1].doubleValue) / 255,
            blue: CGFloat(parts[2].doubleValue) / 255,
            alpha: 1
        )
    }

    var isDark: Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return 0.299 * red + 0.587 * green + 0.114 * blue < 0.5
    }
}

// MARK: - App info

enum AppInfo {
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Claude Web"
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Version \(short) (\(build))"
    }
}

// MARK: - Settings

/// Switches in Settings > Blocking. Tracker blocking lives on `BlockList`.
enum AppSettings {
    private static let hideAppPromptsKey = "HideAppPrompts"
    private static let styleFixKey = "StyleFixEnabled"

    /// Dismiss claude.ai's "get the Claude app" prompts. On unless turned off.
    static var hideAppPrompts: Bool {
        get { UserDefaults.standard.object(forKey: hideAppPromptsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: hideAppPromptsKey) }
    }

    /// The iOS 17.3 style fix. On unless turned off.
    static var styleFixEnabled: Bool {
        get { UserDefaults.standard.object(forKey: styleFixKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: styleFixKey) }
    }
}

// MARK: - Device

enum DeviceInfo {
    /// The hardware identifier, such as "iPhone11,8".
    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var memory: String {
        ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
    }

    static var systemVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    static var summary: String {
        "\(model), \(memory) RAM, iOS \(systemVersion)"
    }
}

// MARK: - User agent

enum UserAgent {
    /// WebKit builds the user agent as "Mozilla/5.0 (iPhone; CPU iPhone OS 17_3_1 like Mac OS X)
    /// AppleWebKit/605.1.15 (KHTML, like Gecko)" followed by this application name. Ending it the way
    /// Mobile Safari does makes the app look like Safari on the same iOS version: sites, Google
    /// sign-in among them, treat a user agent without the Safari token as an embedded web view.
    static var safariApplicationName: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var version = "\(os.majorVersion).\(os.minorVersion)"
        if os.patchVersion > 0 {
            version += ".\(os.patchVersion)"
        }
        return "Version/\(version) Mobile/15E148 Safari/604.1"
    }
}

// MARK: - Script messages

/// WKUserContentController keeps a strong reference to its message handlers;
/// this breaks the cycle between the controller and the view controller that owns it.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Presenting

extension UIViewController {
    /// The view controller currently on top, so sheets can be shown over a pop-up or another sheet.
    var topmostPresented: UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }

    func showAlert(title: String, message: String?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topmostPresented.present(alert, animated: true)
    }
}

// MARK: - JavaScript alert(), confirm() and prompt()

/// WKWebView shows nothing for these unless the app does. Every completion handler must be
/// called exactly once, so each path below calls it, including the one where nothing can be shown.
@MainActor
enum JavaScriptPanels {

    static func alert(_ message: String, from presenter: UIViewController, completion: @escaping () -> Void) {
        let top = presenter.topmostPresented
        guard top.viewIfLoaded?.window != nil else {
            completion()
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion() })
        top.present(alert, animated: true)
    }

    static func confirm(_ message: String, from presenter: UIViewController, completion: @escaping (Bool) -> Void) {
        let top = presenter.topmostPresented
        guard top.viewIfLoaded?.window != nil else {
            completion(false)
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completion(true) })
        top.present(alert, animated: true)
    }

    static func prompt(
        _ message: String,
        defaultText: String?,
        from presenter: UIViewController,
        completion: @escaping (String?) -> Void
    ) {
        let top = presenter.topmostPresented
        guard top.viewIfLoaded?.window != nil else {
            completion(nil)
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completion(alert?.textFields?.first?.text ?? "")
        })
        top.present(alert, animated: true)
    }
}
