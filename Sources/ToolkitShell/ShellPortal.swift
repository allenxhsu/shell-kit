import AppKit
import SyncKit

/// Signing the app in to the toolkit's Portal, and telling the page about it.
///
/// The page syncs; the shell only gets it a credential. A browser tab signs in
/// with Google and keeps a cookie, which a Mac app cannot use, so the app
/// pairs instead: sync-kit's `PairingFlow` opens
/// `<origin>/devices/pair?scheme=<connect scheme>` in a sign-in sheet, the
/// Portal mints a device token and redirects to
/// `<scheme>://connect?url=<origin>&token=<token>`, and the pair goes into the
/// Keychain. Then the shell hands `{ url, token }` to every open page with
/// `window.<name>Host.remote(…)`, and the page's sync module treats them
/// exactly as if they had been typed into its own Sync settings.
///
/// An app opts in by giving `ShellConfig` a `portalOrigin` (or a
/// `connectScheme`); an app that does not has no menu items, no URL type and
/// no new behaviour at all.
public final class ShellPortal: NSObject {
    /// The app's portal. Reading it before `ShellConfig.current` is set is a
    /// programming error, the same as reading the config itself.
    public static let shared = ShellPortal()

    private let config: ShellConfig
    private let defaults: UserDefaults
    private let store: (any PairingStore)?
    private let present: PairingFlow.Present?
    /// Where `remote` goes. The default finds every open document window;
    /// tests hand in a recorder.
    private let deliver: ([String: String]) -> Void

    /// The person's own Portal origin, when they changed it in the Sync… sheet.
    private var defaultsKey: String { "\(config.handlerName).portalOrigin" }

    public init(config: ShellConfig = .current,
                defaults: UserDefaults = .standard,
                store: (any PairingStore)? = nil,
                present: PairingFlow.Present? = nil,
                deliver: (([String: String]) -> Void)? = nil) {
        self.config = config
        self.defaults = defaults
        self.store = store
        self.present = present
        self.deliver = deliver ?? ShellPortal.broadcastToOpenWindows
        super.init()
    }

    // MARK: Where the Portal is

    /// The origin in force: what the person last typed, else the app's default.
    public var origin: String {
        get {
            let stored = defaults.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let chosen = (stored?.isEmpty == false ? stored : nil) ?? config.portalOrigin ?? ""
            return ShellPortal.trimOrigin(chosen)
        }
        set {
            let trimmed = ShellPortal.trimOrigin(newValue)
            // Back to the app's default rather than an empty string, so
            // clearing the field means "forget my change", not "no Portal".
            if trimmed.isEmpty || trimmed == config.portalOrigin {
                defaults.removeObject(forKey: defaultsKey)
            } else {
                defaults.set(trimmed, forKey: defaultsKey)
            }
        }
    }

    public var connectScheme: String? { config.connectScheme }
    public var isConfigured: Bool { config.pairsWithPortal }

    private var flow: PairingFlow {
        PairingFlow(portalOrigin: origin, scheme: config.connectScheme ?? config.handlerName,
                    store: store, present: present)
    }

    // MARK: What the app has

    /// The pairing this Mac already has, or nil. Never throws at the caller:
    /// a Keychain that will not answer is the same as not being paired, and
    /// the person's next move in either case is to sign in again.
    public var pairing: DevicePairing? { try? flow.current() }
    public var isPaired: Bool { pairing != nil }

    // MARK: Signing in and out

    /// Open the sign-in sheet, keep what comes back, tell the pages.
    @discardableResult
    public func pair(label: String? = nil) async throws -> DevicePairing {
        let paired = try await flow.pair(label: label ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        sendToPages(paired)
        return paired
    }

    /// A `<scheme>://connect?…` URL that arrived through the app delegate —
    /// pairing finished after the sheet had already closed, or the person
    /// opened a connect link from somewhere else. Returns false when the URL
    /// is not one of ours, so the delegate can pass it on.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard isConfigured, let paired = try? flow.accept(url) else { return false }
        sendToPages(paired)
        return true
    }

    /// Revoke the token at the Portal when it can be reached, then forget it here.
    @discardableResult
    public func signOut() async throws -> SignOutResult {
        let result = try await flow.signOut()
        // The page's Sync settings are now empty, which is exactly what
        // clearing the fields by hand would have done.
        sendToPages(nil)
        return result
    }

    // MARK: Telling the page

    /// `window.<name>Host.remote({url, token})` into every open page. A page
    /// that opens later gets it from `EditorWindowController` when it reports
    /// ready, so a window is never left syncing to nothing.
    public func sendToPages(_ pairing: DevicePairing?) {
        deliver(ShellPortal.remoteArguments(pairing))
    }

    /// The body of the `remote` message: the pair as the page's Sync settings
    /// would hold them, and two empty strings for "signed out".
    public static func remoteArguments(_ pairing: DevicePairing?) -> [String: String] {
        ["url": pairing?.url ?? "", "token": pairing?.token ?? ""]
    }

    private static func broadcastToOpenWindows(_ arguments: [String: String]) {
        for case let controller as EditorWindowController in
            NSDocumentController.shared.documents.flatMap(\.windowControllers) {
            controller.sendRemote(arguments)
        }
    }

    static func trimOrigin(_ origin: String) -> String {
        var trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    // MARK: The menu items

    /// "Sign in to the toolkit…": the Sync sheet, where the Portal's address
    /// lives and the sign-in sheet starts.
    @objc public func showSyncSheet(_ sender: Any?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = origin
        field.placeholderString = "https://toolkit.example"
        field.lineBreakMode = .byTruncatingTail

        let alert = NSAlert()
        alert.messageText = "Sync \(config.appName) with the toolkit"
        alert.informativeText = isPaired
            ? "This Mac is paired with \(origin). Signing in again replaces the device token it holds."
            : "Sign in with Google in the sheet that opens. The Portal gives this Mac its own token, which you can revoke from its Devices page."
        alert.accessoryView = field
        alert.addButton(withTitle: isPaired ? "Pair Again…" : "Sign In…")
        alert.addButton(withTitle: "Cancel")

        let window = NSApp.keyWindow
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.origin = field.stringValue
            guard !self.origin.isEmpty else {
                self.report(title: "No Portal address", text: "Type the address of the toolkit Portal, such as https://toolkit.example.")
                return
            }
            Task { await self.pairShowingErrors() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: respond) } else { respond(alert.runModal()) }
    }

    @objc public func signOutOfToolkit(_ sender: Any?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.signOut()
                if result.wasPaired, !result.revoked {
                    // The token is gone from this Mac either way. Saying so is
                    // the difference between "done" and "still revoke it".
                    self.report(title: "Signed out on this Mac",
                                text: "The Portal could not be reached, so its device token is still listed. Remove it from the Portal's Devices page when you are next online.")
                }
            } catch {
                self.report(title: "Could not sign out", text: error.localizedDescription)
            }
        }
    }

    private func pairShowingErrors() async {
        do {
            _ = try await pair()
        } catch PairingError.cancelled {
            // The person closed the sheet. Nothing to report.
        } catch {
            report(title: "Could not sign in to the toolkit", text: error.localizedDescription)
        }
    }

    private func report(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Sign out is only ever offered when there is something to sign out of.
    @objc public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(signOutOfToolkit(_:)) ? isPaired : true
    }
}

/// The page's half of the bridge, as far as the shell can check it.
///
/// `js/host.js` names the callbacks it exposes in one place; this reads that
/// list, so a test can catch the two halves drifting apart — a shell that
/// calls `remote` on a page whose vendored `host.js` predates it would
/// otherwise fail silently, in the one code path nobody exercises by hand.
public enum PortalBridge {
    /// The call the shell makes. `arguments` keeps the values out of the
    /// script text, so a token never goes through a JavaScript parser.
    public static func remoteScript(hostObject: String) -> String {
        "\(hostObject).remote({ url, token })"
    }

    /// The names in `globalThis[`${name}Host`] = { load, command, saved, remote };`.
    public static func hostAPINames(inJavaScript source: String) -> Set<String> {
        guard let start = source.range(of: "Host`] = {"),
              let end = source.range(of: "}", range: start.upperBound..<source.endIndex) else { return [] }
        return Set(source[start.upperBound..<end.lowerBound]
            .split(separator: ",")
            .map { $0.split(separator: ":").first.map(String.init) ?? String($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }
}
