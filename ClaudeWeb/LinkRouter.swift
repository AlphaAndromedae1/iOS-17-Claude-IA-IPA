import Foundation

/// Decides where a URL opens: in the app's web view, in an in-app Safari sheet, or in another app.
enum LinkRouter {

    enum Destination {
        /// Load it in the web view (or, for a new window, in a pop-up sheet that keeps `window.opener`).
        case webView
        /// An ordinary web page on another site: show it in an in-app Safari sheet.
        case safariSheet
        /// Not a web page at all (mailto:, tel:, App Store links, ...): hand it to iOS.
        case otherApp
    }

    /// Claude itself. Pages on these domains always stay in the app.
    static let appDomains = ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com"]

    /// Sign-in, bot-check and payment pages that claude.ai sends you through and expects you back from.
    static let flowDomains = [
        "accounts.google.com", "accounts.youtube.com",
        "appleid.apple.com", "idmsa.apple.com",
        "challenges.cloudflare.com",
        "checkout.stripe.com", "hooks.stripe.com", "js.stripe.com", "pay.stripe.com",
    ]

    /// Schemes WebKit handles on its own; they must never be handed to another app.
    private static let internalSchemes: Set<String> = ["about", "blob", "data", "javascript"]

    static func isAppHost(_ host: String?) -> Bool { matches(host, domains: appDomains) }
    static func isFlowHost(_ host: String?) -> Bool { matches(host, domains: flowDomains) }

    /// A navigation inside an existing frame.
    static func destination(for url: URL, mainFrame: Bool, userTapped: Bool) -> Destination {
        let scheme = url.scheme?.lowercased() ?? ""
        if internalSchemes.contains(scheme) { return .webView }
        guard scheme == "http" || scheme == "https" else { return .otherApp }

        // Embedded frames (Cloudflare checks, artifacts, payment fields) belong to the page.
        if !mainFrame { return .webView }
        if isAppHost(url.host) || isFlowHost(url.host) { return .webView }

        // A tapped link to another site opens in Safari. Redirects, form posts and scripted
        // navigations stay here, so single sign-on and OAuth round trips can finish.
        return userTapped ? .safariSheet : .webView
    }

    /// A link or script asking for a new window (target="_blank", window.open).
    static func newWindowDestination(for url: URL?) -> Destination {
        // window.open() with no URL yet is how sign-in pop-ups usually start.
        guard let url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .webView }
        if internalSchemes.contains(scheme) { return .webView }
        guard scheme == "http" || scheme == "https" else { return .otherApp }
        return isAppHost(url.host) || isFlowHost(url.host) ? .webView : .safariSheet
    }

    private static func matches(_ host: String?, domains: [String]) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
