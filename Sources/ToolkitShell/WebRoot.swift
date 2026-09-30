import Foundation
import WebKit
import UniformTypeIdentifiers

/// Where the web app's files are, and the custom scheme that serves them.
///
/// ES modules will not load from `file://`, so the page is served from
/// `<scheme>://app/…` instead: a real origin, which also gives the page its
/// own `localStorage` (where the shared appearance preference lives).
public enum WebRoot {
    public static var scheme: String { ShellConfig.current.scheme }
    public static var indexURL: URL { indexURL(scheme: scheme) }
    public static func indexURL(scheme: String) -> URL { URL(string: "\(scheme)://app/index.html")! }

    /// Where the running app's page comes from: see `directory(for:bundledWeb:platform:)`.
    public static var directory: URL {
        directory(for: ShellConfig.current, bundledWeb: Bundle.main.resourceURL?.appendingPathComponent("web"),
                  platform: .current)
    }

    /// On iOS, the app's configured `webRoot` — the folder it bundled, and
    /// nothing guessed. On macOS, the bundled copy in a built app
    /// (`Contents/Resources/web`, when it has an `index.html`); the
    /// repository itself under `swift run` and `swift test`.
    public static func directory(for config: ShellConfig, bundledWeb: URL?, platform: ShellPlatform) -> URL {
        switch platform {
        case .ios:
            return config.webRoot
        case .macos:
            if let bundledWeb, FileManager.default.fileExists(atPath: bundledWeb.appendingPathComponent("index.html").path) {
                return bundledWeb
            }
            return config.repositoryRoot
        }
    }

    /// The file a request names, or nil when it points outside the web root.
    public static func file(for url: URL, under root: URL) -> URL? {
        let path = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard file.path == base || file.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        return file
    }

    public static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "html": return "text/html"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    /// Text types get a charset; fonts and images do not.
    public static func contentType(for file: URL) -> String {
        let mime = mimeType(for: file)
        return mime.hasPrefix("text/") || mime == "application/json" || mime == "image/svg+xml" ? mime + "; charset=utf-8" : mime
    }
}

/// Serves `<scheme>://app/…` from the web root, on both platforms.
public final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL?

    /// `root` nil: `WebRoot.directory`, looked up per request.
    public init(root: URL? = nil) {
        self.root = root
        super.init()
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = WebRoot.file(for: url, under: root ?? WebRoot.directory),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": WebRoot.contentType(for: file),
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
