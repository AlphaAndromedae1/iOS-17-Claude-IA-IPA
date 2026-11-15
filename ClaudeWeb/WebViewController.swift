import SafariServices
import UIKit
import WebKit

/// Shows claude.ai full screen in a single WKWebView.
///
/// iOS 16.4 and later ship a WebKit that runs claude.ai unmodified, so unlike wrappers
/// built for older iOS this one does not intercept, transpile or re-evaluate the site's
/// JavaScript. Doing that for every module is what exhausted memory and made iOS stop
/// the web process. The page gets two small read-only scripts (see `PageScripts`), and
/// requests to known trackers are blocked inside WebKit (see `BlockList`).
final class WebViewController: UIViewController {

    private static let homeURL = URL(string: "https://claude.ai/")!
    private static let newChatURL = URL(string: "https://claude.ai/new")!
    private static let lastPageKey = "LastPageURL"
    private static let downloadsFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Downloads", isDirectory: true)

    /// iOS stops the web content process when memory runs low, most often while the app
    /// is in the background. The page is reloaded quietly, unless it keeps happening.
    private static let crashWindow: TimeInterval = 120
    private static let crashLimit = 3

    private lazy var webView: WKWebView = makeWebView()
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let bottomFill = UIView()
    private let errorView = ErrorView()
    private let blockList = BlockList()
    private let networkLog = NetworkLog()

    private var progressTimer: Timer?
    private var failedURL: URL?
    private var crashDates: [Date] = []
    fileprivate var stopLog: [(date: Date, reason: String)] = []
    private var pagesFinished = 0
    /// Set by Troubleshoot > Reload Without Add-ons, until the app is next opened.
    private var addOnsDisabled = false
    private var reloadWhenActive = false
    private var downloads: [WKDownload: URL] = [:]
    private var statusBarStyle: UIStatusBarStyle = .default

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }

    // MARK: - Setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .appBackground
        bottomFill.backgroundColor = .appBackground

        progressBar.trackTintColor = .clear
        progressBar.progressTintColor = .accent
        progressBar.isHidden = true
        spinner.hidesWhenStopped = true
        errorView.isHidden = true
        errorView.onReload = { [weak self] in self?.reloadPage() }
        errorView.onOptions = { [weak self] in self?.showMenu() }

        let subviews: [UIView] = [webView, bottomFill, progressBar, spinner, errorView]
        for subview in subviews {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        // The page sits inside the safe area; the strips behind the status bar and the home
        // indicator are native views tinted to match the page (see `applyPageColors`).
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: safe.topAnchor),
            webView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),

            bottomFill.topAnchor.constraint(equalTo: safe.bottomAnchor),
            bottomFill.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            progressBar.topAnchor.constraint(equalTo: safe.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(deviceDidShake), name: .deviceDidShake, object: nil)
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)

        // Downloads are only kept until they've been shared; drop any left over from last time.
        try? FileManager.default.removeItem(at: Self.downloadsFolder)

        spinner.startAnimating()
        // Install the block list first, so not even the first page load reaches a tracker.
        let firstPage = restoredPage() ?? Self.homeURL
        blockList.apply(to: webView.configuration.userContentController) { [weak self] in
            self?.load(firstPage)
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()  // persistent, so you stay signed in
        configuration.applicationNameForUserAgent = UserAgent.safariApplicationName
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.dataDetectorTypes = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let content = configuration.userContentController
        content.addUserScript(WKUserScript(
            source: PageScripts.pageColors, injectionTime: .atDocumentEnd, forMainFrameOnly: true
        ))
        content.add(WeakScriptMessageHandler(self), name: PageScripts.pageColorsMessage)
        content.addUserScript(WKUserScript(
            source: PageScripts.networkObserver, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        content.add(WeakScriptMessageHandler(self), name: PageScripts.networkMessage)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        // Lets Safari's Web Inspector on a Mac attach to the page. Debug builds from Xcode only;
        // the release IPA can't be inspected.
        webView.isInspectable = true
        #endif
        return webView
    }

    // MARK: - Loading

    private func load(_ url: URL) {
        failedURL = nil
        errorView.isHidden = true
        webView.load(URLRequest(url: url))
    }

    /// Reloads the current web page, or goes to claude.ai if there isn't one (after the test page, say).
    private func reloadPage(resettingStops: Bool = true) {
        if resettingStops {
            crashDates.removeAll()
        }
        let current = webView.url.flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
        if current == nil || failedURL != nil {
            spinner.startAnimating()
        }
        load(failedURL ?? current ?? Self.homeURL)
    }

    private func showError(title: String, message: String) {
        endProgress()
        spinner.stopAnimating()
        errorView.show(title: title, message: message)
    }

    private func handleLoadError(_ error: Error, pageWasShowing: Bool) {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        // 102: the load became a download or was cancelled by policy. 204: handled by a plug-in.
        if error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204) { return }
        // A failure after the page is already up isn't worth hiding it behind a full-screen error.
        if pageWasShowing { return }

        failedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        showError(title: "Couldn't load Claude", message: error.localizedDescription)
    }

    // MARK: - Progress bar

    private func beginProgress() {
        progressBar.alpha = 1
        progressBar.isHidden = false
        progressBar.setProgress(0.1, animated: false)
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(
            timeInterval: 0.1, target: self, selector: #selector(updateProgress), userInfo: nil, repeats: true
        )
    }

    @objc private func updateProgress() {
        let progress = Float(max(0.1, webView.estimatedProgress))
        if progress > progressBar.progress {
            progressBar.setProgress(progress, animated: true)
        }
    }

    private func endProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        guard !progressBar.isHidden else { return }
        progressBar.setProgress(1, animated: true)
        UIView.animate(withDuration: 0.25, delay: 0.15, options: [], animations: {
            self.progressBar.alpha = 0
        }, completion: { _ in
            // A new load may have started while this faded out.
            if self.progressTimer == nil {
                self.progressBar.isHidden = true
            }
        })
    }

    // MARK: - App state

    @objc private func appDidEnterBackground() {
        rememberCurrentPage()
    }

    @objc private func appWillEnterForeground() {
        if reloadWhenActive {
            reloadWhenActive = false
            load(webView.url ?? Self.homeURL)
        }
    }

    /// Reopen the conversation you were in, like Safari reopening its tab.
    private func rememberCurrentPage() {
        guard let url = webView.url, url.host?.lowercased() == "claude.ai" else { return }
        if url.path.hasPrefix("/chat/") || url.path.hasPrefix("/project/") {
            UserDefaults.standard.set(url.absoluteString, forKey: Self.lastPageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.lastPageKey)
        }
    }

    private func restoredPage() -> URL? {
        guard let string = UserDefaults.standard.string(forKey: Self.lastPageKey),
              let url = URL(string: string),
              url.scheme == "https", url.host?.lowercased() == "claude.ai" else { return nil }
        return url
    }

    // MARK: - Page colours

    private func applyPageColors(top: UIColor, bottom: UIColor) {
        view.backgroundColor = top
        bottomFill.backgroundColor = bottom
        let style: UIStatusBarStyle = top.isDark ? .lightContent : .darkContent
        if style != statusBarStyle {
            statusBarStyle = style
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    // MARK: - Opening things elsewhere

    private func openInSafariSheet(_ url: URL) {
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = .accent
        safari.dismissButtonStyle = .close
        topmostPresented.present(safari, animated: true)
    }

    private func openInOtherApp(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            if !opened {
                self?.showAlert(title: "Can't open this link", message: url.absoluteString)
            }
        }
    }

    private func share(_ file: URL) {
        let presenter = topmostPresented
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        // Whatever was chosen (Save to Files, AirDrop, ...) has its own copy by now.
        sheet.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: file)
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
    }

    // MARK: - Menu (shake the phone)

    @objc private func deviceDidShake() {
        // Only from the main screen; a sheet or alert on top has its own controls.
        guard presentedViewController == nil else { return }
        showMenu()
    }

    private func showMenu() {
        guard presentedViewController == nil else { return }
        let sheet = UIAlertController(title: AppInfo.name, message: AppInfo.version, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "Reload", style: .default) { [weak self] _ in
            self?.reloadPage()
        })
        sheet.addAction(UIAlertAction(title: "New Chat", style: .default) { [weak self] _ in
            self?.load(WebViewController.newChatURL)
        })
        sheet.addAction(UIAlertAction(title: "Open Copied Link", style: .default) { [weak self] _ in
            self?.openCopiedLink()
        })
        if let url = webView.url, url.scheme == "https" {
            sheet.addAction(UIAlertAction(title: "Open in Safari", style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }
        sheet.addAction(UIAlertAction(title: "Privacy Report", style: .default) { [weak self] _ in
            self?.showPrivacyReport()
        })
        sheet.addAction(UIAlertAction(title: "Troubleshoot…", style: .default) { [weak self] _ in
            self?.showTroubleshooting()
        })
        sheet.addAction(UIAlertAction(title: "Clear Cache", style: .default) { [weak self] _ in
            self?.clearCache()
        })
        sheet.addAction(UIAlertAction(title: "Sign Out and Reset…", style: .destructive) { [weak self] _ in
            self?.confirmReset()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    /// The email sign-in link opens in Safari when tapped in Mail. Copying it and opening it
    /// here signs you in to the app instead.
    private func openCopiedLink() {
        let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", LinkRouter.isAppHost(url.host) else {
            showAlert(
                title: "No Claude link copied",
                message: "Copy a claude.ai link first, then try again. For the sign-in email, "
                    + "press and hold the link in Mail and choose Copy Link."
            )
            return
        }
        spinner.startAnimating()
        load(url)
    }

    // MARK: - Troubleshooting

    private func showTroubleshooting() {
        let sheet = UIAlertController(
            title: "Troubleshoot",
            message: "Try these one at a time to narrow down why the page stops.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Load a Test Page", style: .default) { [weak self] _ in
            self?.loadTestPage()
        })
        sheet.addAction(UIAlertAction(title: "Reload Without Add-ons", style: .default) { [weak self] _ in
            self?.reloadWithoutAddOns()
        })
        sheet.addAction(UIAlertAction(title: "Copy Diagnostics", style: .default) { [weak self] _ in
            self?.copyDiagnostics()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        topmostPresented.present(sheet, animated: true)
    }

    /// A tiny page made by the app itself, with no network. If even this stops, WebKit is failing in
    /// this app no matter what page it shows; if it stays up, the problem is specific to claude.ai.
    private func loadTestPage() {
        failedURL = nil
        crashDates.removeAll()
        errorView.isHidden = true
        spinner.startAnimating()
        webView.loadHTMLString(Self.testPageHTML, baseURL: nil)
    }

    /// Takes out everything the app adds to the page (both scripts and the tracker block list) until
    /// the app is next opened, to rule them out as the cause.
    private func reloadWithoutAddOns() {
        addOnsDisabled = true
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()
        crashDates.removeAll()
        reloadPage()
        showAlert(
            title: "Add-ons are off",
            message: "Claude is loading without the app's scripts and tracker blocking. They come back the next "
                + "time you open the app."
        )
    }

    private func copyDiagnostics() {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var lines = [
            "\(AppInfo.name) diagnostics",
            AppInfo.version,
            DeviceInfo.summary,
            "Add-ons (page scripts, tracker blocking): " + (addOnsDisabled ? "off for this session" : "on"),
            "Tracker blocking: \(blockList.isEnabled ? "on" : "off"), \(blockList.hosts.count) addresses",
            "Current page: " + (webView.url?.host ?? webView.url?.scheme ?? "none"),
            "Pages finished loading this session: \(pagesFinished)",
            "Times the page stopped this session: \(stopLog.count)",
        ]
        lines += stopLog.map { "  \(time.string(from: $0.date))  \($0.reason)" }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        showAlert(title: "Diagnostics copied", message: "Paste them into your chat. They contain nothing from your conversations.")
    }

    private static let testPageHTML = """
    <!doctype html>
    <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      body { font: -apple-system-body; margin: 0; padding: 32px 24px; background: #262624; color: #f0eee6; }
      h1 { font-size: 24px; margin-top: 0; }
      p { line-height: 1.5; color: #c2c0b6; }
      a { color: #d97757; font-weight: 600; }
    </style></head>
    <body>
    <h1>The web view works</h1>
    <p>The app made this page itself, without the internet. If you can read this, WebKit is running.</p>
    <p id="js">JavaScript is <b>not</b> running.</p>
    <p>If this page stays up while claude.ai keeps stopping, the problem is specific to claude.ai on this phone.
    If this page stops too, WebKit itself is failing in this app, which usually comes from something
    installed on the phone, such as a jailbreak tweak.</p>
    <p><a href="https://claude.ai/">Back to Claude</a></p>
    <script>document.getElementById("js").textContent = "JavaScript is running.";</script>
    </body></html>
    """

    private func showPrivacyReport() {
        let report = NetworkReportViewController(log: networkLog, blockList: blockList)
        report.onFinish = { [weak self] changed in
            // With add-ons off for troubleshooting, the new list waits until the app is next opened.
            guard changed, let self, !self.addOnsDisabled else { return }
            // Scripts that already loaded stay loaded, so reload for the new list to take full effect.
            self.blockList.apply(to: self.webView.configuration.userContentController) { [weak self] in
                self?.reloadPage()
            }
        }
        present(UINavigationController(rootViewController: report), animated: true)
    }

    /// Fixes a page that is stuck on an old or broken copy of the site; keeps you signed in.
    private func clearCache() {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeFetchCache,
            WKWebsiteDataTypeServiceWorkerRegistrations,
        ]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            self?.reloadPage()
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
            UserDefaults.standard.removeObject(forKey: WebViewController.lastPageKey)
            let store = WKWebsiteDataStore.default()
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                self?.spinner.startAnimating()
                self?.load(WebViewController.homeURL)
            }
        })
        present(alert, animated: true)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let destination = LinkRouter.destination(
            for: url,
            mainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            userTapped: navigationAction.navigationType == .linkActivated
        )
        switch destination {
        case .webView:
            let staysInApp = LinkRouter.isAppHost(url.host) || LinkRouter.isFlowHost(url.host)
            decisionHandler(staysInApp ? .allowWithoutTryingAppLink : .allow)
            if url.scheme == "https" || url.scheme == "http" {
                networkLog.recordNavigation(to: url, mainFrame: navigationAction.targetFrame?.isMainFrame ?? true)
            }
        case .safariSheet:
            decisionHandler(.cancel)
            openInSafariSheet(url)
        case .otherApp:
            decisionHandler(.cancel)
            openInOtherApp(url)
        }
    }

    /// WebKit reports each request a content rule list stopped. This is WebKit's private
    /// `WKNavigationDelegatePrivate` callback (iOS 14 and later), the one Safari's own privacy
    /// counts rely on. If WebKit stopped calling it, blocking would still work; only the
    /// "Blocked This Session" list in the Privacy Report would stay empty.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(
        _ webView: WKWebView,
        contentRuleListWithIdentifier identifier: String?,
        performedAction action: AnyObject?,
        forURL url: URL?
    ) {
        networkLog.recordBlocked(url)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.shouldDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        beginProgress()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        errorView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pagesFinished += 1
        endProgress()
        spinner.stopAnimating()
        errorView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        endProgress()
        handleLoadError(error, pageWasShowing: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        endProgress()
        // The spinner is still up only if nothing has been shown yet.
        handleLoadError(error, pageWasShowing: !spinner.isAnimating)
    }

    /// Only called if WebKit doesn't use the private version below.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webContentStopped(reasonCode: nil)
    }

    /// WebKit's private `WKNavigationDelegatePrivate` version of the callback above, which also says
    /// why the page stopped (`_WKProcessTerminationReason`). When a delegate has it, WebKit calls it
    /// instead of the public one.
    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        webContentStopped(reasonCode: reason)
    }
}

// MARK: - When the page stops

extension WebViewController {

    /// Wording for `_WKProcessTerminationReason`.
    static func describeStop(_ code: Int?) -> String {
        switch code {
        case 0?: return "went over the memory limit"
        case 1?: return "used too much processor time"
        case 2?: return "stopped by the app"
        case 3?: return "crashed"
        case let other?: return "stopped (code \(other))"
        case nil: return "stopped (no reason given)"
        }
    }

    fileprivate func webContentStopped(reasonCode code: Int?) {
        endProgress()
        stopLog.append((date: Date(), reason: Self.describeStop(code)))
        if stopLog.count > 30 {
            stopLog.removeFirst(stopLog.count - 30)
        }

        // Stopped while in the background: bring the page back when the app is next opened.
        if UIApplication.shared.applicationState == .background {
            reloadWhenActive = true
            return
        }

        // The Troubleshoot test page (about:blank) stopping is a result worth showing, not retrying.
        if webView.url?.scheme == "about" {
            failedURL = Self.homeURL
            showError(
                title: "The test page stopped too",
                message: "Even a tiny page the app made itself \(Self.describeStop(code)). So WebKit is failing in "
                    + "this app whatever the page, not because of claude.ai. That usually comes from something "
                    + "installed on the phone, such as a jailbreak tweak that loads into apps or web pages."
                    + "\n\n\(DeviceInfo.summary) · \(AppInfo.version)"
            )
            return
        }

        let now = Date()
        crashDates = crashDates.filter { now.timeIntervalSince($0) < Self.crashWindow } + [now]
        if crashDates.count >= Self.crashLimit {
            failedURL = webView.url ?? Self.homeURL
            showError(title: "Claude keeps stopping", message: stopMessage(code: code))
            return
        }
        reloadPage(resettingStops: false)
    }

    private func stopMessage(code: Int?) -> String {
        let count = crashDates.count
        let advice: String
        switch code {
        case 0?:
            advice = "iOS stopped the page \(count) times because it went over the memory limit for web pages. "
                + "Close other apps and tap Reload."
        case 3?:
            advice = "The page crashed \(count) times in a row. That's a crash, not low memory, so clearing the "
                + "cache won't fix it. Options > Troubleshoot can narrow down the cause."
        default:
            advice = "iOS stopped the page \(count) times in a short while (\(Self.describeStop(code))). "
                + "Options > Troubleshoot can narrow down the cause."
        }
        return advice + "\n\n\(DeviceInfo.summary) · \(AppInfo.version)"
    }
}

// MARK: - WKUIDelegate

extension WebViewController: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let url = navigationAction.request.url
        switch LinkRouter.newWindowDestination(for: url) {
        case .safariSheet:
            if let url { openInSafariSheet(url) }
            return nil
        case .otherApp:
            if let url { openInOtherApp(url) }
            return nil
        case .webView:
            let popup = PopupViewController(configuration: configuration)
            popup.downloadDelegate = self
            topmostPresented.present(UINavigationController(rootViewController: popup), animated: true)
            return popup.webView
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // Claude's own pages (dictation, voice mode) don't need a second web prompt on top of
        // the iOS microphone prompt; anything else asks as usual.
        decisionHandler(LinkRouter.isAppHost(origin.host) ? .grant : .prompt)
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

// MARK: - WKScriptMessageHandler

extension WebViewController: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Pop-ups share this configuration; only the main page counts.
        guard message.webView === webView else { return }

        if message.name == PageScripts.networkMessage {
            networkLog.recordBatch(message.body)
            return
        }
        guard message.name == PageScripts.pageColorsMessage,
              let body = message.body as? [String: Any],
              let top = UIColor(rgbComponents: body["top"]),
              let bottom = UIColor(rgbComponents: body["bottom"]) else { return }
        applyPageColors(top: top, bottom: bottom)
    }
}

// MARK: - WKDownloadDelegate

extension WebViewController: WKDownloadDelegate {

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let folder = Self.downloadsFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            return
        }
        var name = (suggestedFilename as NSString).lastPathComponent
        if name.isEmpty || name == "/" {
            name = "download"
        }
        let destination = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        downloads[download] = destination
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = downloads.removeValue(forKey: download) else { return }
        // The share sheet offers Save to Files, Save Image, AirDrop and so on.
        share(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: download)
        showAlert(title: "Download failed", message: error.localizedDescription)
    }
}
