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

    public init(appName: String, handlerName: String, scheme: String, fileSuffix: String, documentNoun: String,
                untitledName: String? = nil, importedTypes: [String] = [], defaultPDFName: String? = nil,
                repositoryRoot: URL, minimumWindowSize: CGSize = CGSize(width: 1000, height: 640),
                windowFrameAutosaveName: String? = nil) {
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
    }

    /// `window.<handlerName>Host`, the object the page exposes for load / command / saved.
    public var hostObject: String { "window.\(handlerName)Host" }

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
