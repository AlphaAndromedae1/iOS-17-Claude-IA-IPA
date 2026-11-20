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
    private let styleSheetFetcher = StyleSheetFetcher()

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
        errorView.onOptions = { [weak self] in self?.showSettings() }

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
        center.addObserver(self, selector: #selector(memoryWarning),
                           name: UIApplication.didReceiveMemoryWarningNotification, object: nil)

        DebugLog.shared.info("App", "Opened \(AppInfo.version)", details: DeviceInfo.summary)

        // Downloads are only kept until they've been shared; drop any left over from last time.
        try? FileManager.default.removeItem(at: Self.downloadsFolder)

        spinner.startAnimating()
        // Install the content rules first, so the very first page load already has the iOS 17
        // style fix and tracker blocking.
        let firstPage = restoredPage() ?? Self.homeURL
        installContentRules { [weak self] in
            self?.load(firstPage)
        }
    }

    /// Installs the iOS 17 style fix rules and the tracker block list together. Each takes effect for
    /// requests made after `completion`.
    private func installContentRules(completion: @escaping () -> Void) {
        StyleFixRules.compile { [weak self] styleFixRules in
            guard let self else { return }
            self.blockList.compileRuleList { [weak self] trackerRules in
                guard let self else { return }
                let controller = self.webView.configuration.userContentController
                controller.removeAllContentRuleLists()
                if !self.addOnsDisabled {
                    if let styleFixRules, AppSettings.styleFixEnabled { controller.add(styleFixRules) }
                    if let trackerRules { controller.add(trackerRules) }
                }
                completion()
            }
        }
    }

    /// Adds the page scripts that Settings > Blocking has switched on. Takes effect on the next page load.
    private func installUserScripts(on content: WKUserContentController) {
        content.removeAllUserScripts()
        guard !addOnsDisabled else { return }
        func add(_ source: String, _ time: WKUserScriptInjectionTime) {
            content.addUserScript(WKUserScript(source: source, injectionTime: time, forMainFrameOnly: true))
        }
        if AppSettings.styleFixEnabled {
            if let styleFix = PageScripts.styleFix {
                // First, so it's watching before the page's first style sheet arrives.
                add(styleFix, .atDocumentStart)
            } else {
                DebugLog.shared.error(
                    "Style fix", "style-fix.js is missing from the app",
                    details: "Without it, claude.ai's style sheets are blocked but never put back, so pages "
                        + "will look unstyled. The build should have copied Shared/style-fix.js into the app."
                )
            }
        }
        add(PageScripts.errorReporter, .atDocumentStart)
        add(PageScripts.networkObserver, .atDocumentStart)
        if AppSettings.hideAppPrompts {
            add(PageScripts.appPrompts, .atDocumentEnd)
        }
        add(PageScripts.pageColors, .atDocumentEnd)
    }

    /// After a switch in Settings > Blocking changes: reinstall scripts and rules, then reload.
    private func applyBlockingSettings() {
        guard !addOnsDisabled else { return }  // everything comes back when the app is reopened
        installUserScripts(on: webView.configuration.userContentController)
        installContentRules { [weak self] in
            self?.reloadPage()
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
        content.addScriptMessageHandler(styleSheetFetcher, contentWorld: .page, name: PageScripts.styleSheetMessage)
        for name in [PageScripts.pageColorsMessage, PageScripts.networkMessage,
                     PageScripts.pageErrorMessage, PageScripts.appPromptMessage] {
            content.add(WeakScriptMessageHandler(self), name: name)
        }
        installUserScripts(on: content)

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

        let failing = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        DebugLog.shared.error(
            "Loading", error.localizedDescription,
            details: "\(error.domain) error \(error.code)\nAddress: \(failing?.absoluteString ?? "unknown")"
                + (pageWasShowing ? "\nThe page was already showing, so no error screen was shown." : "")
        )
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
        DebugLog.shared.save()
    }

    @objc private func memoryWarning() {
        DebugLog.shared.warning("App", "iOS reported low memory")
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
        sheet.addAction(UIAlertAction(title: "Settings & Debug Log", style: .default) { [weak self] _ in
            self?.showSettings()
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

    // MARK: - Settings and troubleshooting

    private func showSettings() {
        guard presentedViewController == nil else { return }
        let actions = SettingsViewController.Actions(
            addOnsEnabled: { [weak self] in !(self?.addOnsDisabled ?? false) },
            diagnostics: { [weak self] in self?.diagnosticsText() ?? "" },
            makePrivacyReport: { [weak self] in self?.makePrivacyReport() ?? UIViewController() },
            trackerBlocking: .init(
                isOn: { [weak self] in self?.blockList.isEnabled ?? true },
                set: { [weak self] on in
                    self?.blockList.isEnabled = on
                    DebugLog.shared.info("Settings", "Tracker blocking turned \(on ? "on" : "off")")
                    self?.applyBlockingSettings()
                }
            ),
            hideAppPrompts: .init(
                isOn: { AppSettings.hideAppPrompts },
                set: { [weak self] on in
                    AppSettings.hideAppPrompts = on
                    DebugLog.shared.info("Settings", "Hiding app prompts turned \(on ? "on" : "off")")
                    self?.applyBlockingSettings()
                }
            ),
            styleFix: .init(
                isOn: { AppSettings.styleFixEnabled },
                set: { [weak self] on in
                    AppSettings.styleFixEnabled = on
                    DebugLog.shared.info("Settings", "iOS 17 style fix turned \(on ? "on" : "off")")
                    self?.applyBlockingSettings()
                }
            ),
            loadTestPage: { [weak self] in self?.loadTestPage() },
            reloadWithoutAddOns: { [weak self] in self?.reloadWithoutAddOns() },
            clearCache: { [weak self] in self?.clearCache() },
            signOutAndReset: { [weak self] in self?.signOutAndReset() }
        )
        present(UINavigationController(rootViewController: SettingsViewController(actions: actions)), animated: true)
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
            message: "Claude is loading without the app's scripts and tracker blocking, including the iOS 17 style "
                + "fix, so claude.ai may crash again. Everything comes back the next time you open the app."
        )
    }

    /// For Settings > Copy Diagnostics: what's needed to work out a problem, nothing from conversations.
    private func diagnosticsText() -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var lines = [
            "\(AppInfo.name) diagnostics",
            AppInfo.version,
            DeviceInfo.summary,
            "Add-ons (iOS 17 style fix, page scripts, tracker blocking): "
                + (addOnsDisabled ? "off for this session" : "on"),
            "Style sheets loaded through the iOS 17 fix: \(styleSheetFetcher.loadedSheets), fixed: "
                + (styleSheetFetcher.fixedSheets.isEmpty ? "none" : styleSheetFetcher.fixedSheets.joined(separator: ", ")),
            "Tracker blocking: \(blockList.isEnabled ? "on" : "off"), \(blockList.hosts.count) addresses",
            "Current page: " + (webView.url?.host ?? webView.url?.scheme ?? "none"),
            "Pages finished loading this session: \(pagesFinished)",
            "Times the page stopped this session: \(stopLog.count)",
        ]
        lines += stopLog.map { "  \(time.string(from: $0.date))  \($0.reason)" }
        let styleFix = DebugLog.shared.entries.filter { $0.category == "Style fix" }.suffix(15)
        lines += ["", "Style fix activity:"]
        lines += styleFix.isEmpty ? ["  none"] : styleFix.map { "  " + DebugLog.describe($0) }
        let problems = DebugLog.shared.text(onlyProblems: true, limit: 25)
        lines += ["", "Latest problems from the debug log:", problems.isEmpty ? "  none" : problems]
        return lines.joined(separator: "\n")
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

    private func makePrivacyReport() -> UIViewController {
        let report = NetworkReportViewController(log: networkLog, blockList: blockList)
        report.onFinish = { [weak self] changed in
            // With add-ons off for troubleshooting, the new list waits until the app is next opened.
            guard changed, let self, !self.addOnsDisabled else { return }
            // Scripts that already loaded stay loaded, so reload for the new list to take full effect.
            self.installContentRules { [weak self] in
                self?.reloadPage()
            }
        }
        return report
    }

    /// Fixes a page that is stuck on an old or broken copy of the site; keeps you signed in.
    private func clearCache() {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeFetchCache,
            WKWebsiteDataTypeServiceWorkerRegistrations,
        ]
        DebugLog.shared.info("App", "Cleared the cache")
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            self?.reloadPage()
        }
    }

    private func signOutAndReset() {
        UserDefaults.standard.removeObject(forKey: Self.lastPageKey)
        DebugLog.shared.info("App", "Signed out and reset website data")
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.spinner.startAnimating()
            self?.load(WebViewController.homeURL)
        }
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
            if AppSettings.hideAppPrompts && url.scheme?.lowercased() == "claude" {
                // The official app can't sign in on iOS 17 any more; stay here.
                DebugLog.shared.info("App prompt", "Stopped claude.ai from opening the Claude app", details: url.absoluteString)
            } else {
                openInOtherApp(url)
            }
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
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            logResponse(response)
        }
        decisionHandler(navigationResponse.shouldDownload ? .download : .allow)
    }

    private func logResponse(_ response: HTTPURLResponse) {
        let address = Self.shortAddress(response.url)
        if (response.value(forHTTPHeaderField: "cf-mitigated") ?? "").lowercased() == "challenge" {
            DebugLog.shared.info("Loading", "Cloudflare security check on \(address)")
        } else if response.statusCode >= 400 {
            let ray = response.value(forHTTPHeaderField: "cf-ray").map { "\nCloudflare ray: \($0)" } ?? ""
            DebugLog.shared.warning(
                "Loading", "HTTP \(response.statusCode) from \(address)",
                details: HTTPURLResponse.localizedString(forStatusCode: response.statusCode).capitalized + ray
            )
        }
    }

    /// Host and path only, without the query or fragment, which can hold tokens.
    static func shortAddress(_ url: URL?) -> String {
        guard let url else { return "unknown address" }
        guard let host = url.host else { return url.scheme ?? "unknown address" }
        return host + url.path
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        beginProgress()
        DebugLog.shared.info("Loading", "Started \(Self.shortAddress(webView.url))")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        errorView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pagesFinished += 1
        DebugLog.shared.info("Loading", "Finished \(Self.shortAddress(webView.url))")
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
        stopLog.append((date: Date(), reason: Self.describeStop(code) + (addOnsDisabled ? " (add-ons off)" : "")))
        DebugLog.shared.error(
            "Web page", "The page \(Self.describeStop(code))",
            details: "Address: \(Self.shortAddress(webView.url))\n"
                + "WebKit reason code: \(code.map { String($0) } ?? "not given")\n"
                + "App state: \(UIApplication.shared.applicationState == .background ? "background" : "foreground")\n"
                + "On iOS 17, a crash while reading a style sheet is what the iOS 17 style fix works around. "
                + "Settings > Debug Log shows whether a sheet was fixed."
        )
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
                + "cache won't fix it. Settings & Debug Log shows the details and can narrow down the cause."
        default:
            advice = "iOS stopped the page \(count) times in a short while (\(Self.describeStop(code))). "
                + "Settings & Debug Log shows the details and can narrow down the cause."
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
            if let url, AppSettings.hideAppPrompts, url.scheme?.lowercased() == "claude" {
                DebugLog.shared.info("App prompt", "Stopped claude.ai from opening the Claude app", details: url.absoluteString)
            } else if let url {
                openInOtherApp(url)
            }
            return nil
        case .webView:
            DebugLog.shared.info("Window", "Opened a pop-up for \(Self.shortAddress(url))")
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

// MARK: - Errors reported by the page

extension WebViewController {

    /// A message from `PageScripts.errorReporter`: `{ kind, message, details, page }`.
    fileprivate func logPageError(_ body: Any) {
        guard let report = body as? [String: Any], let message = report["message"] as? String else { return }
        let kind = report["kind"] as? String ?? "exception"
        var details = report["details"] as? String ?? ""
        if let page = report["page"] as? String, !page.isEmpty {
            details += (details.isEmpty ? "" : "\n") + "Page: \(page)"
        }

        switch kind {
        case "resource":
            // A file that didn't load. Trackers the app blocks are expected to fail, so they're only noted.
            if let url = URL(string: report["url"] as? String ?? ""), let host = url.host,
               let rule = blockList.coveringEntry(for: host) {
                DebugLog.shared.info("Blocked", "\(message) (on the tracker list as \(rule))", details: details)
            } else {
                DebugLog.shared.warning("Page", message, details: details)
            }
        case "csp":
            DebugLog.shared.warning("Page", message, details: details)
        default:
            DebugLog.shared.error("Page", message, details: details)
        }
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
        if message.name == PageScripts.pageErrorMessage {
            logPageError(message.body)
            return
        }
        if message.name == PageScripts.appPromptMessage, let report = message.body as? [String: Any] {
            DebugLog.shared.info(
                "App prompt", "Dismissed a “get the app” prompt",
                details: "It said: \(report["text"] as? String ?? "")\nHow: \(report["how"] as? String ?? "")"
            )
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
        DebugLog.shared.info("Download", "Downloaded \(downloads[download]?.lastPathComponent ?? "a file")")
        guard let file = downloads.removeValue(forKey: download) else { return }
        // The share sheet offers Save to Files, Save Image, AirDrop and so on.
        share(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: download)
        DebugLog.shared.error("Download", "Download failed: \(error.localizedDescription)")
        showAlert(title: "Download failed", message: error.localizedDescription)
    }
}
