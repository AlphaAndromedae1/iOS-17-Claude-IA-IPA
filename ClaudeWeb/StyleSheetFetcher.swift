import Foundation
import WebKit

/// The native half of `PageScripts.styleFix`.
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
            if !fixedSheets.contains(name) && fixedSheets.count < 50 {
                fixedSheets.append(name)
            }
            let count = (body["count"] as? NSNumber)?.intValue ?? 0
            DebugLog.shared.info(
                "Style fix", "Fixed \(name) for iOS 17",
                details: "Replaced \(count) relative colour expression\(count == 1 ? "" : "s") that crash WebKit "
                    + "on iOS 17.3.\nFile: \(fixed.components(separatedBy: "?")[0])"
            )
            replyHandler(nil, nil)
            return
        }

        if let failed = body["failed"] as? String {
            DebugLog.shared.error(
                "Style fix", "Couldn't fix \(URL(string: failed)?.lastPathComponent ?? failed)",
                details: "The style sheet was handed back to WebKit unchanged, so the page may crash.\n"
                    + "Reason: \(body["error"] as? String ?? "unknown")\nFile: \(failed.components(separatedBy: "?")[0])"
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
