import Foundation

/// Safari's native entry point for the extension. The extension never messages the app, so this
/// just answers, so that a stray native message can't leave Safari waiting.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: [], completionHandler: nil)
    }
}
