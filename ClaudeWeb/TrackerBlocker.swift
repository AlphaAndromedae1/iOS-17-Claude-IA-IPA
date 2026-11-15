import Foundation
import WebKit

/// The built-in lists. Kept apart from `BlockList` so they can be read from anywhere.
enum TrackerLists {

    /// Services whose only job is measuring, recording or advertising. None of them provides a
    /// Claude feature, so blocking them can't take anything away from the site, and a service
    /// claude.ai doesn't use simply never matches.
    ///
    /// Deliberately left out, because a site can depend on them: feature-flag services (Statsig,
    /// LaunchDarkly, Amplitude Experiment), support chat (Intercom), bot checks (Cloudflare
    /// Turnstile, reCAPTCHA, hCaptcha) and payments (Stripe, including its fraud checks).
    static let defaultHosts: [String] = [
        // Product analytics
        "segment.io", "segment.com",
        "api.amplitude.com", "api2.amplitude.com", "cdn.amplitude.com",
        "mixpanel.com", "mxpnl.com",
        "heapanalytics.com",
        "google-analytics.com", "analytics.google.com", "googletagmanager.com",
        "cloudflareinsights.com",
        "clarity.ms",
        "hs-analytics.net",
        // Session recording
        "hotjar.com", "hotjar.io",
        "fullstory.com",
        "logrocket.io", "lr-ingest.io", "lr-ingest.com", "lr-in.com",
        "mouseflow.com",
        "smartlook.com",
        // Error and performance reporting
        "sentry.io", "sentry-cdn.com",
        "browser-intake-datadoghq.com", "browser-intake-datadoghq.eu",
        "browser-intake-us3-datadoghq.com", "browser-intake-us5-datadoghq.com",
        "browser-intake-ap1-datadoghq.com", "datadoghq-browser-agent.com",
        "nr-data.net", "js-agent.newrelic.com",
        // Advertising and conversion tracking
        "doubleclick.net", "googleadservices.com", "googlesyndication.com",
        "facebook.net",
        "ads-twitter.com", "analytics.twitter.com",
        "ads.linkedin.com", "snap.licdn.com",
        "redditstatic.com", "alb.reddit.com", "pixel-config.reddit.com",
        "analytics.tiktok.com",
        "bat.bing.com",
        "ct.pinterest.com",
        "tr.snapchat.com", "sc-static.net",
        "adnxs.com", "criteo.com", "criteo.net",
    ]

    /// What claude.ai can't work without: the site and its app files, artifacts, and the sign-in,
    /// security-check and payment pages it relies on.
    static let essentialHosts: [String] =
        ["claude.ai", "assets-proxy.anthropic.com", "claudeusercontent.com"] + LinkRouter.flowDomains

    /// The host is essential, or belongs to one that is.
    static func isEssential(_ host: String) -> Bool {
        essentialHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Blocking an address also blocks everything under it, so a parent domain of an essential
    /// host (anthropic.com, say) can't be blocked either.
    static func canBlock(_ host: String) -> Bool {
        !essentialHosts.contains { $0 == host || $0.hasSuffix("." + host) || host.hasSuffix("." + $0) }
    }

    /// Turns what someone typed or pasted ("https://cdn.example.com/x.js", "*.example.com")
    /// into a bare host name, or nil if it isn't one.
    static func normalizedHost(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("*.") {
            text.removeFirst(2)
        }
        if let host = URL(string: text)?.host, !host.isEmpty {
            text = host
        } else if let host = URL(string: "https://" + text)?.host, !host.isEmpty {
            text = host
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."), !text.contains(".."),
              text.count <= 253, text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }
}

/// The addresses the app blocks: the default list, minus any you switched off, plus any you added.
/// Blocking happens inside WebKit with a content rule list, the mechanism Safari content blockers
/// use, so a blocked request never leaves the phone.
@MainActor
final class BlockList {

    private static let ruleListIdentifier = "ClaudeWebBlockList"

    private enum Key {
        static let added = "BlockList.Added"
        static let removedDefaults = "BlockList.RemovedDefaults"
        static let disabled = "BlockList.Disabled"
    }

    private let defaults = UserDefaults.standard

    var isEnabled: Bool {
        get { !defaults.bool(forKey: Key.disabled) }
        set { defaults.set(!newValue, forKey: Key.disabled) }
    }

    /// Hosts you added yourself.
    private(set) var addedHosts: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.added) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.added) }
    }

    /// Default hosts you switched off.
    private var removedDefaults: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.removedDefaults) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.removedDefaults) }
    }

    var hosts: [String] {
        Set(TrackerLists.defaultHosts).subtracting(removedDefaults).union(addedHosts).sorted()
    }

    /// The list entry that blocks `host`: the host itself or a domain it belongs to.
    func coveringEntry(for host: String) -> String? {
        hosts.first { host == $0 || host.hasSuffix("." + $0) }
    }

    func block(_ host: String) {
        guard TrackerLists.canBlock(host) else { return }
        if TrackerLists.defaultHosts.contains(host) {
            removedDefaults.remove(host)
        } else {
            addedHosts.insert(host)
        }
    }

    /// Stops blocking `host` by removing whichever entry covers it.
    func unblock(_ host: String) {
        let entry = coveringEntry(for: host) ?? host
        if TrackerLists.defaultHosts.contains(entry) {
            removedDefaults.insert(entry)
        }
        addedHosts.remove(entry)
    }

    func restoreDefaults() {
        addedHosts = []
        removedDefaults = []
    }

    /// One block rule per host, matching the host and all of its subdomains.
    private func ruleListJSON() -> String? {
        let rules: [[String: Any]] = hosts.map { host in
            let pattern = "^[^:]+://+([^:/]+\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[:/]"
            return ["trigger": ["url-filter": pattern], "action": ["type": "block"]]
        }
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Compiles the current list, or gives nil when blocking is off or the list can't be compiled.
    /// `WebViewController.installContentRules` installs it alongside the iOS 17 style fix rules.
    func compileRuleList(completion: @escaping (WKContentRuleList?) -> Void) {
        guard isEnabled, let json = ruleListJSON() else {
            completion(nil)
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.ruleListIdentifier, encodedContentRuleList: json
        ) { list, error in
            if let error {
                DebugLog.shared.error("Tracker blocking", "Couldn't install the block list", details: error.localizedDescription)
            }
            completion(list)
        }
    }
}
