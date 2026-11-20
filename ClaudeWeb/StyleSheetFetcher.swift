import Foundation
import WebKit

/// The rules half of the iOS 17.3 style fix: WebKit isn't allowed to load style sheets from Claude's
/// own servers itself, so it never parses the originals that crash it. `Shared/style-fix.js` loads
/// each of them instead and adds a corrected copy to the page. A content rule list is checked
/// before a request is even made, so unlike changing the `<link>` from a script there's no race
/// with the download.
enum StyleFixRules {

    static let identifier = "ClaudeWebStyleFix"

    /// Keep in step with `OWN_HOST` in `Shared/style-fix.js` and `SafariExtension/Resources/rules.json`.
    static let hosts = ["claude.ai", "claude.com", "anthropic.com"]

    @MainActor
    static func compile(completion: @escaping (WKContentRuleList?) -> Void) {
        let rules: [[String: Any]] = hosts.map { host in
            let pattern = "^https?://([^:/]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[:/]"
            return [
                "trigger": ["url-filter": pattern, "resource-type": ["style-sheet"]],
                "action": ["type": "block"],
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else {
            completion(nil)
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: json
        ) { list, error in
            if let error {
                DebugLog.shared.error(
                    "Style fix", "Couldn't install the iOS 17 style fix rules",
                    details: error.localizedDescription + "\nWithout them, claude.ai may crash on iOS 17.3."
                )
            }
            completion(list)
        }
    }
}

/// The native half of `Shared/style-fix.js` in the app.
///
/// The page script downloads claude.ai's style sheets itself, but browsers only let a page read a
/// file from another server if that server allows it (CORS). When it doesn't, the script asks the
/// app, which isn't bound by that rule, to download the file. It sends the page's cookies and user
/// agent so the request looks like the page's own. Only https files on Claude's own domains are
/// fetched.
///
/// The script also reports each sheet it had to fix, which Settings > Copy Diagnostics lists.
@MainActor
final class StyleSheetFetcher: NSObject, WKScriptMessageHandlerWithReply {

    /// File names of the style sheets fixed this session.
    private(set) var fixedSheets: [String] = []
    /// Style sheets the page script loaded in WebKit's place this session, fixed or not.
    private(set) var loadedSheets = 0

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any] else {
            replyHandler(nil, "Unexpected message")
            return
        }

        if let fixed = body["fixed"] as? String {
            let name = URL(string: fixed)?.lastPathComponent ?? fixed
            let count = (body["count"] as? NSNumber)?.intValue ?? 0
            let hasCount = (body["hasCount"] as? NSNumber)?.intValue ?? 0
            let how = body["how"] as? String == "constructed"
                ? "\nAdded as a constructed style sheet, because the page's Content Security Policy refused a <style>."
                : ""
            let file = "\nFile: \(fixed.components(separatedBy: "?")[0])"
            loadedSheets += 1
            if count + hasCount > 0 {
                if !fixedSheets.contains(name) && fixedSheets.count < 50 {
                    fixedSheets.append(name)
                }
                var changes: [String] = []
                if count > 0 {
                    changes.append("replaced \(count) relative colour expression\(count == 1 ? "" : "s")")
                }
                if hasCount > 0 {
                    changes.append("disabled \(hasCount) :has() selector\(hasCount == 1 ? "" : "s") that test an attribute")
                }
                let summary = changes.joined(separator: " and ")
                let sentence = summary.prefix(1).uppercased() + String(summary.dropFirst())
                DebugLog.shared.info(
                    "Style fix", "Fixed \(name) for iOS 17",
                    details: sentence + ", which crash WebKit on iOS 17.3." + how + file
                )
            } else {
                DebugLog.shared.info(
                    "Style fix", "Loaded \(name), nothing to fix",
                    details: "WebKit isn't allowed to load Claude's style sheets itself, so the app loaded this "
                        + "one. It had no relative colours." + how + file
                )
            }
            replyHandler(nil, nil)
            return
        }

        if let failed = body["failed"] as? String {
            DebugLog.shared.error(
                "Style fix", "Couldn't load \(URL(string: failed)?.lastPathComponent ?? failed)",
                details: "The page will be missing these styles.\n"
                    + "Reason: \(body["error"] as? String ?? "unknown")\nFile: \(failed.components(separatedBy: "?")[0])"
            )
            replyHandler(nil, nil)
            return
        }

        if let seen = body["seen"] as? String {
            let address = seen.components(separatedBy: "?")[0]
            DebugLog.shared.info(
                "Style fix", "Style sheet from another server: \(URL(string: seen)?.host ?? address)",
                details: "The iOS 17 style fix only covers Claude's own servers, so WebKit loads this one "
                    + "itself. If the page still crashes, this could be the file.\nFile: \(address)"
            )
            replyHandler(nil, nil)
            return
        }

        guard let string = body["url"] as? String,
              let url = URL(string: string),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              LinkRouter.isAppHost(host) else {
            replyHandler(nil, "Only Claude's own style sheets can be fetched")
            return
        }
        let userAgent = body["userAgent"] as? String

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
            request.setValue("text/css,*/*;q=0.1", forHTTPHeaderField: "Accept")
            if let userAgent, !userAgent.isEmpty {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == domain || host.hasSuffix("." + domain)
            }
            for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
                request.setValue(value, forHTTPHeaderField: field)
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let text = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) }
                DispatchQueue.main.async {
                    if let text, (200..<300).contains(status) {
                        replyHandler(text, nil)
                    } else {
                        replyHandler(nil, error?.localizedDescription ?? "HTTP \(status)")
                    }
                }
            }.resume()
        }
    }
}
