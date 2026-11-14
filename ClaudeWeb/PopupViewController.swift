import UIKit
import WebKit

/// A window the page opened itself, typically a Google or Apple sign-in pop-up. It is shown as
/// a sheet and keeps its link to the page that opened it, so the sign-in result gets back to
/// claude.ai, and it closes itself when the page calls `window.close()`.
final class PopupViewController: UIViewController {

    /// Must be returned to WebKit from `webView(_:createWebViewWith:for:windowFeatures:)`.
    let webView: WKWebView
    weak var downloadDelegate: WKDownloadDelegate?

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .appBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close)
        )

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        updateTitle()
    }

    @objc private func close() {
        (presentingViewController ?? self).dismiss(animated: true)
    }

    private func updateTitle() {
        if let title = webView.title, !title.isEmpty {
            navigationItem.title = title
        } else {
            navigationItem.title = webView.url?.host
        }
    }
}

extension PopupViewController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // Everything web-based stays in the pop-up so the sign-in can finish; only links
        // that belong to another app (mailto:, tel:, ...) leave it.
        if let url = navigationAction.request.url,
           LinkRouter.destination(for: url, mainFrame: false, userTapped: false) == .otherApp {
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
            return
        }
        decisionHandler(.allowWithoutTryingAppLink)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.shouldDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloadDelegate
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloadDelegate
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateTitle()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateTitle()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

extension PopupViewController: WKUIDelegate {

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // A pop-up opening another window: show it in this sheet instead of stacking sheets.
        if navigationAction.request.url != nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        JavaScriptPanels.alert(message, from: self, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        JavaScriptPanels.confirm(message, from: self, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        JavaScriptPanels.prompt(prompt, defaultText: defaultText, from: self, completion: completionHandler)
    }
}

extension WKNavigationActionPolicy {
    /// Like `.allow`, but WebKit won't hand the URL to an app that claims it as a universal link.
    /// Without it, a claude.ai link or sign-in redirect can jump to the official Claude app, if
    /// an old copy is installed, instead of staying here. WebKit's private
    /// `_WKNavigationActionPolicyAllowWithoutTryingAppLink`; Firefox for iOS relies on it too.
    static let allowWithoutTryingAppLink = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
}

extension WKNavigationResponse {
    /// Responses WebKit can't display, or that the server marks as a file to save.
    var shouldDownload: Bool {
        if !canShowMIMEType { return true }
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        return disposition.lowercased().hasPrefix("attachment")
    }
}
