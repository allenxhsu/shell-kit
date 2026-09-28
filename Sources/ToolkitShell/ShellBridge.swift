import Foundation
import WebKit

/// Which shell is running. The page reads it as `platform` from `host.js`.
public enum ShellPlatform: String, Sendable {
    case ios
    case macos

    public static var current: ShellPlatform {
        #if os(iOS)
        return .ios
        #else
        return .macos
        #endif
    }
}

/// A page the app can talk to: a Mac document window, or the iPhone app's web
/// view. What a handler in `ShellConfig.handlers` answers through.
@MainActor
public protocol ShellPage {
    /// `window.<handlerName>Host.event(event)` in the page. The event has to
    /// be JSON (strings, numbers, booleans, `NSNull`, arrays and dictionaries
    /// of those); one that is not is logged and dropped. Sent before the page
    /// has reported ready, it waits and arrives, in order, once it has.
    func send(_ event: [String: Any])
}

/// Where a page message goes. The shell's own types first, always; then the
/// app's handlers; anything else is logged.
public enum ShellMessage {
    /// The types the shell answers itself. An app cannot take one over by
    /// naming a handler after it.
    ///
    /// Document messages (`changed`, `pdf`, `new`, `open`, `save`) are the Mac
    /// shell's; the iPhone shell accepts and ignores them, so one page can run
    /// under both.
    public static let builtInTypes: Set<String> = [
        "ready", "changed", "saveFile", "pdf", "new", "open", "save", "log", "portal.pair", "portal.signOut",
    ]

    public enum Route: Equatable, Sendable {
        /// One of `builtInTypes`; `builtIn` was called.
        case builtIn(String)
        /// An app handler took it.
        case handled(String)
        /// Neither the shell nor the app knows this type.
        case unhandled(String)
        /// Not a dictionary with a string `type`.
        case malformed
    }

    /// Send one page message where it belongs.
    @MainActor
    @discardableResult
    public static func dispatch(_ body: Any, handlers: [String: ShellHandler], page: any ShellPage,
                                builtIn: (_ type: String, _ body: [String: Any]) -> Void) -> Route {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return .malformed }
        if builtInTypes.contains(type) {
            builtIn(type, message)
            return .builtIn(type)
        }
        guard let handler = handlers[type] else { return .unhandled(type) }
        handler(message, page)
        return .handled(type)
    }
}

/// How an event reaches the page: JSON text passed as an argument and parsed
/// there, so no value from the app is ever spliced into script source.
public enum ShellEvent {
    /// The event as compact JSON with sorted keys, or nil when it holds a
    /// value JSON cannot carry (a `Date`, a `URL`: send their strings).
    public static func json(_ event: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The body `callAsyncJavaScript` runs, with `json` as its one argument.
    /// A page whose vendored `host.js` predates `event` is left alone rather
    /// than thrown at.
    public static func script(hostObject: String) -> String {
        "const host = \(hostObject); if (host && typeof host.event === 'function') host.event(JSON.parse(json));"
    }
}

/// Events for one page, held until it reports ready. A page that reloads
/// (the web content process was killed, or the page reloaded itself) waits
/// again: an event sent into a page that is still loading would be lost.
public struct ShellEventQueue {
    public private(set) var isReady = false
    private var pending: [[String: Any]] = []

    public init() {}

    /// Returns what to deliver now: this event if the page is ready, else nothing.
    public mutating func enqueue(_ event: [String: Any]) -> [[String: Any]] {
        if isReady { return [event] }
        pending.append(event)
        return []
    }

    /// The page reported ready: everything that waited, in order.
    public mutating func pageReady() -> [[String: Any]] {
        isReady = true
        defer { pending.removeAll() }
        return pending
    }

    /// A new page is loading; hold events until it is ready.
    public mutating func pageUnloaded() { isReady = false }
}

/// The scripts both shells put into the page.
public enum ShellBridge {
    /// Runs before any of the page's modules: tells `host.js` which handler it
    /// talks to and which shell this is, and routes page errors, which would
    /// otherwise vanish, to the app's log.
    public static func bootstrapScript(handlerName name: String, platform: ShellPlatform) -> String {
        """
        window.__toolkitHost = '\(name)';
        window.__toolkitPlatform = '\(platform.rawValue)';
        window.addEventListener('error', (e) => webkit.messageHandlers.\(name).postMessage({ type: 'log', text: String(e.message) + ' @ ' + e.filename + ':' + e.lineno }));
        window.addEventListener('unhandledrejection', (e) => webkit.messageHandlers.\(name).postMessage({ type: 'log', text: 'unhandled: ' + String(e.reason) }));
        """
    }

    /// An app, not a web page: no pinch or double-tap zoom. Keeps whatever
    /// else the page's own viewport says (`viewport-fit=cover`, say).
    public static let fixedViewportScript = """
        (() => {
          let meta = document.querySelector('meta[name="viewport"]');
          if (!meta) {
            meta = document.createElement('meta');
            meta.name = 'viewport';
            meta.content = 'width=device-width, initial-scale=1';
            (document.head || document.documentElement).appendChild(meta);
          }
          const keep = meta.content.split(',').map((s) => s.trim())
            .filter((s) => s && !/^(minimum-scale|maximum-scale|user-scalable)\\s*=/.test(s));
          meta.content = keep.concat(['minimum-scale=1', 'maximum-scale=1', 'user-scalable=no']).join(', ');
        })();
        """

    /// A name the page gave an export, made safe to be a file name in a
    /// folder of the shell's choosing: no path separators, not hidden.
    public static func exportFileName(_ name: String) -> String {
        let flat = name.map { "/\\:".contains($0) ? "-" : String($0) }.joined()
        let trimmed = flat.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "." })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "export" : trimmed
    }
}

/// `WKUserContentController` retains its handlers; this keeps the page's
/// owner (a window controller, the iPhone web view's controller) out of that cycle.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
