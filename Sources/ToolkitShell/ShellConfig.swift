import Foundation
import CoreGraphics

/// Everything that differs between one toolkit app and the next. Set
/// `ShellConfig.current` once, before the first document or menu is made.
public struct ShellConfig: Sendable {
    /// Shown in the app menu and window titles: "SysML Modeler".
    public var appName: String
    /// One word, lower case: "sysml". Names the WebKit message handler
    /// (`webkit.messageHandlers.sysml`) and the page-side object (`window.sysmlHost`).
    public var handlerName: String
    /// The custom scheme the page is served from: "sysml-app" → `sysml-app://app/index.html`.
    public var scheme: String
    /// The suffix a saved document gets: ".sysml.json".
    public var fileSuffix: String
    /// What the app calls its document, for messages: "model", "plan".
    public var documentNoun: String
    /// The name the page reports for a fresh document: "Untitled model".
    public var untitledName: String
    /// Content types the document can read besides JSON (imports that become untitled documents).
    public var importedTypes: [String]
    /// The file name to suggest for a multi-page PDF when the page names none.
    public var defaultPDFName: String
    /// The repository root, used when the app runs unbundled (`swift run`, `swift test`).
    /// Pass `#filePath`-relative from the app's own source so it resolves to that repo.
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

    public init(appName: String, handlerName: String, scheme: String, fileSuffix: String, documentNoun: String,
                untitledName: String? = nil, importedTypes: [String] = [], defaultPDFName: String? = nil,
                repositoryRoot: URL, minimumWindowSize: CGSize = CGSize(width: 1000, height: 640),
                windowFrameAutosaveName: String? = nil,
                portalOrigin: String? = nil, connectScheme: String? = nil) {
        self.appName = appName
        self.handlerName = handlerName
        self.scheme = scheme
        self.fileSuffix = fileSuffix
        self.documentNoun = documentNoun
        self.untitledName = untitledName ?? "Untitled \(documentNoun)"
        self.importedTypes = importedTypes
        self.defaultPDFName = defaultPDFName ?? "\(handlerName).pdf"
        self.repositoryRoot = repositoryRoot
        self.minimumWindowSize = minimumWindowSize
        self.windowFrameAutosaveName = windowFrameAutosaveName ?? "\(handlerName)-editor"
        self.portalOrigin = portalOrigin.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.connectScheme = connectScheme ?? (portalOrigin == nil ? nil : handlerName)
    }

    /// `window.<handlerName>Host`, the object the page exposes for load / command / saved / remote.
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
