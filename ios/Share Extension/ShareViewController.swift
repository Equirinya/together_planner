import receive_sharing_intent

/// Share Extension entry point. `RSIShareViewController` (from the
/// receive_sharing_intent plugin) reads the shared items, stores them in the
/// shared App Group container, and redirects into the host app via the
/// `ShareMedia-<bundleId>` URL scheme, where the Flutter side picks them up.
class ShareViewController: RSIShareViewController {
    // Return true to redirect to the host app immediately after receiving the
    // shared content (a recipe link), rather than showing a compose UI.
    override func shouldAutoRedirect() -> Bool {
        return true
    }
}
