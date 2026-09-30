import Foundation
import CoreGraphics

/// An app's answer to a page message the shell does not handle itself:
/// `post({ type: 'echo', text })` in the page reaches `handlers["echo"]` with
/// the whole message, and `page.send(…)` answers through
/// `window.<name>Host.event(…)`. Always called on the main actor.
public typealias ShellHandler = @MainActor @Sendable (_ message: [String: Any], _ page: any ShellPage) -> Void

/// Everything that differs between one toolkit app and the next. Set
/// `ShellConfig.current` once, before the first document or menu is made
/// (`ShellApp.run` and `ShellScene` both do it for you).
///
/// A Mac document app gives the document fields; an iPhone app, which has no
/// documents, gives its names, its `webRoot`, and whatever handlers and deep
/// links it wants — everything else has a default.
public struct ShellConfig: Sendable {
    /// Shown in the app menu and window titles: "SysML Modeler".
    public var appName: String
    /// One word, lower case: "sysml". Names the WebKit message handler
    /// (`webkit.messageHandlers.sysml`) and the page-side object (`window.sysmlHost`).
    public var handlerName: String
    /// The custom scheme the page is served from: "sysml-app" → `sysml-app://app/index.html`.
    /// Defaults to `<handlerName>-app`.
    public var scheme: String
    /// The suffix a saved document gets: ".sysml.json". Mac document apps only; defaults to ".json".
    public var fileSuffix: String
    /// What the app calls its document, for messages: "model", "plan". Defaults to "document".
    public var documentNoun: String
    /// The name the page reports for a fresh document: "Untitled model".
    public var untitledName: String
    /// Content types the document can read besides JSON (imports that become untitled documents).
    public var importedTypes: [String]
    /// The file name to suggest for a multi-page PDF when the page names none.
    public var defaultPDFName: String
    /// The repository root, used when the app runs unbundled (`swift run`, `swift test`).
    /// Pass `#filePath`-relative from the app's own source so it resolves to that repo.
    /// Defaults to `webRoot`.
    public var repositoryRoot: URL
    public var minimumWindowSize: CGSize
    public var windowFrameAutosaveName: String

    /// Where the toolkit's Portal lives: `https://toolkit.example`. This is the
    /// *default* — the person can point the app somewhere else (a Portal on the
    /// LAN, a staging deployment) in the Sync… sheet, and what they typed wins
    /// from then on. `ShellPortal.shared.origin` is the one in force.
    public var portalOrigin: String?
    /// The URL scheme the Portal redirects to when pairing finishes:
    /// `sysml` → `sysml://connect?url=…&token=…`. Nil means this app does not
    /// pair: no menu items, no URL type, nothing new in the bundle.
    ///
    /// Setting `portalOrigin` opts an app in, and the scheme then follows
    /// `handlerName`, which is what every app's `toolkit-app.json` already
    /// says. Pass one explicitly to differ, or to pair with a Portal the
    /// person supplies and the app has no default for.
    ///
    /// Whatever it is, the app's bundle has to declare it:
    /// `node ../shell-kit/scripts/url-types.mjs <scheme> "<app name>"` writes
    /// the `CFBundleURLTypes` block for the build script's `Info.plist`.
    public var connectScheme: String?

    /// The app's deep-link scheme: `flow` → `flow://task/42` arrives in the
    /// page as `event({ type: 'open', url: 'flow://task/42' })`, queued until
    /// the page has reported ready. Nil: the app takes no deep links. The
    /// bundle has to declare it, as it declares the connect scheme; the two
    /// may be the same scheme, and a `<scheme>://connect?…` link then still
    /// goes to pairing first.
    public var urlScheme: String?
    /// Page messages whose `type` is not one the shell handles itself
    /// (`ShellMessage.builtInTypes`), by type. A built-in type listed here is
    /// never called: the shell's own meaning wins.
    public var handlers: [String: ShellHandler]
    /// The folder the page is served from on iOS: the app's bundled copy,
    /// `Bundle.main.url(forResource: "web", withExtension: nil)!`. Defaults to
    /// `repositoryRoot`, else the bundle's `web` folder. On macOS the bundled
    /// `Contents/Resources/web` still wins, then `repositoryRoot`, as before.
    public var webRoot: URL

    public init(appName: String, handlerName: String, scheme: String? = nil, fileSuffix: String = ".json",
                documentNoun: String = "document",
                untitledName: String? = nil, importedTypes: [String] = [], defaultPDFName: String? = nil,
                repositoryRoot: URL? = nil, minimumWindowSize: CGSize = CGSize(width: 1000, height: 640),
                windowFrameAutosaveName: String? = nil,
                portalOrigin: String? = nil, connectScheme: String? = nil,
                urlScheme: String? = nil, handlers: [String: ShellHandler] = [:], webRoot: URL? = nil) {
        self.appName = appName
        self.handlerName = handlerName
        self.scheme = scheme ?? "\(handlerName)-app"
        self.fileSuffix = fileSuffix
        self.documentNoun = documentNoun
        self.untitledName = untitledName ?? "Untitled \(documentNoun)"
        self.importedTypes = importedTypes
        self.defaultPDFName = defaultPDFName ?? "\(handlerName).pdf"
        let bundledWeb = Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true)
            ?? Bundle.main.bundleURL.appendingPathComponent("web", isDirectory: true)
        let web = webRoot ?? repositoryRoot ?? bundledWeb
        self.webRoot = web
        self.repositoryRoot = repositoryRoot ?? web
        self.minimumWindowSize = minimumWindowSize
        self.windowFrameAutosaveName = windowFrameAutosaveName ?? "\(handlerName)-editor"
        self.portalOrigin = portalOrigin.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.connectScheme = connectScheme ?? (portalOrigin == nil ? nil : handlerName)
        self.urlScheme = urlScheme.flatMap { $0.isEmpty ? nil : $0 }
        self.handlers = handlers
    }

    /// The event a deep link becomes, or nil when the URL is not in `urlScheme`.
    public func openEvent(for url: URL) -> [String: Any]? {
        guard let mine = urlScheme?.lowercased(), url.scheme?.lowercased() == mine else { return nil }
        return ["type": "open", "url": url.absoluteString]
    }

    /// `window.<handlerName>Host`, the object the page exposes for load / command / saved / remote / event.
    public var hostObject: String { "window.\(handlerName)Host" }

    /// Whether this app pairs with the Portal at all. Everything the Portal
    /// adds — the menu items, the URL type, the `remote` message — hangs off this.
    public var pairsWithPortal: Bool { connectScheme?.isEmpty == false }

    nonisolated(unsafe) private static var stored: ShellConfig?
    /// The running app's configuration. Reading it before it is set is a programming error.
    public static var current: ShellConfig {
        get {
            guard let c = stored else { fatalError("ShellConfig.current was read before the app set it") }
            return c
        }
        set { stored = newValue }
    }
    public static var isConfigured: Bool { stored != nil }
}
