import Foundation
import SyncKit
#if os(macOS)
import AppKit
#endif

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
///
/// The same object serves both shells. On the Mac the menu items and the Sync
/// sheet drive it (`ShellPortalMac.swift`); on the iPhone the page does, by
/// posting `portal.pair` and `portal.signOut`, and `remote` goes to the
/// app's web view instead of to document windows.
public final class ShellPortal: NSObject {
    /// The app's portal. Reading it before `ShellConfig.current` is set is a
    /// programming error, the same as reading the config itself.
    public static let shared = ShellPortal()

    let config: ShellConfig
    private let defaults: UserDefaults
    private let store: (any PairingStore)?
    private let present: PairingFlow.Present?
    /// Where `remote` goes. The default finds every open document window;
    /// tests hand in a recorder.
    private let deliver: ([String: String]) -> Void

    /// The person's own Portal origin, when they changed it in the Sync… sheet.
    private var defaultsKey: String { "\(config.handlerName).portalOrigin" }

    public init(config: ShellConfig = ShellConfig.current,
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
        let paired = try await flow.pair(label: label ?? ShellPortal.deviceLabel)
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

    #if os(macOS)
    private static func broadcastToOpenWindows(_ arguments: [String: String]) {
        for case let controller as EditorWindowController in
            NSDocumentController.shared.documents.flatMap(\.windowControllers) {
            controller.sendRemote(arguments)
        }
    }

    /// What the Portal's Devices page will call this Mac.
    static var deviceLabel: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
    #else
    /// The iPhone app's web views; `remote` is main-actor work there.
    private static func broadcastToOpenWindows(_ arguments: [String: String]) {
        Task { @MainActor in ShellWebController.broadcastRemote(arguments) }
    }

    /// The iPhone shell passes `UIDevice.current.name`; this is only the fallback.
    static var deviceLabel: String { ProcessInfo.processInfo.hostName }
    #endif

    static func trimOrigin(_ origin: String) -> String {
        var trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
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
