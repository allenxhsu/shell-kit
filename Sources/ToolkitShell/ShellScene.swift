#if os(iOS)
import SwiftUI
import UIKit
import WebKit
import SyncKit

/// The iPhone shell: one full-screen web view showing the app's bundled page.
///
/// ```swift
/// @main struct FlowApp: App {
///     var body: some Scene {
///         ShellScene(config: ShellConfig(appName: "Flow", handlerName: "flow", portalOrigin: "https://toolkit.example",
///                                        urlScheme: "flow", handlers: ["haptic": { _, _ in … }],
///                                        webRoot: Bundle.main.url(forResource: "web", withExtension: nil)!))
///     }
/// }
/// ```
///
/// The page is served from `<scheme>://app/…` out of `webRoot`, by the same
/// scheme handler, path guard and MIME table as the Mac shell, and learns it
/// is on a phone from `platform` in `host.js`. What the Mac does with
/// documents and menus has no counterpart here; what it does with the
/// Portal does — the page posts `portal.pair` / `portal.signOut` and gets
/// `remote({url, token})` back — and the rest is:
///
/// - `saveFile {name, base64}`: the share sheet, which offers Save to Files.
/// - `<input type="file">`: WebKit's own picker (Files, Photos, camera).
/// - `<urlScheme>://…` opened from anywhere: `event({ type: 'open', url })`,
///   held until the page has reported ready (so a cold launch loses nothing).
/// - any other message type: `config.handlers[type](message, page)`, and
///   `page.send(event)` answers through `event(…)`.
public struct ShellScene: Scene {
    private let config: ShellConfig

    public init(config: ShellConfig) {
        ShellConfig.current = config
        self.config = config
    }

    public var body: some Scene {
        WindowGroup {
            ShellRootView(config: config)
        }
    }
}

/// The window's content. The container runs edge to edge in the page's own
/// background colour; the web view inside it keeps to the safe area, so the
/// page never lays out under the status bar, the notch or the home indicator
/// and needs no `env(safe-area-inset-*)`. WebKit moves content out of the
/// keyboard's way by itself.
struct ShellRootView: View {
    let config: ShellConfig
    @State private var link = ShellPageLink()

    var body: some View {
        ShellWebView(config: config, link: link)
            .ignoresSafeArea()
            .onOpenURL { url in link.open(url) }
    }
}

/// Connects `onOpenURL`, which the view gets, to the page's controller, which
/// the representable makes — and holds a URL that arrives before it exists.
final class ShellPageLink {
    private weak var controller: ShellWebController?
    private var waiting: [URL] = []

    init() {}

    @MainActor
    func attach(_ controller: ShellWebController) {
        self.controller = controller
        let early = waiting
        waiting.removeAll()
        for url in early { controller.open(url) }
    }

    @MainActor
    func open(_ url: URL) {
        if let controller { controller.open(url) } else { waiting.append(url) }
    }
}

struct ShellWebView: UIViewRepresentable {
    let config: ShellConfig
    let link: ShellPageLink

    func makeCoordinator() -> ShellWebController { ShellWebController(config: config) }

    func makeUIView(context: Context) -> UIView {
        link.attach(context.coordinator)
        return context.coordinator.container
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// The page, its message channel, and everything the shell does for it.
@MainActor
final class ShellWebController: NSObject, ShellPage, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let config: ShellConfig
    /// Edge to edge, in the page's background colour.
    let container = UIView()
    /// Inside the container's safe area.
    let webView: WKWebView
    private var events = ShellEventQueue()
    private var backgroundObservation: NSKeyValueObservation?

    /// Every live page, for `remote` after a sign-in or sign-out.
    private static let live = NSHashTable<ShellWebController>.weakObjects()

    init(config: ShellConfig) {
        self.config = config
        let wk = WKWebViewConfiguration()
        wk.setURLSchemeHandler(BundleSchemeHandler(root: config.webRoot), forURLScheme: config.scheme)
        wk.allowsInlineMediaPlayback = true
        wk.userContentController.addUserScript(WKUserScript(
            source: ShellBridge.bootstrapScript(handlerName: config.handlerName, platform: .ios),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        wk.userContentController.addUserScript(WKUserScript(
            source: ShellBridge.fixedViewportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: wk)
        super.init()
        wk.userContentController.add(WeakMessageHandler(self), name: config.handlerName)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        let scroll = webView.scrollView
        scroll.backgroundColor = .clear
        scroll.bounces = false
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 1
        #if DEBUG
        webView.isInspectable = true
        #endif

        container.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        let safe = container.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: safe.topAnchor),
            webView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        // The strips outside the safe area follow the page's background, so
        // the page looks as if it ran to the edges.
        backgroundObservation = webView.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.matchPageBackground() }
        }

        Self.live.add(self)
        webView.load(URLRequest(url: WebRoot.indexURL(scheme: config.scheme)))
    }

    // MARK: Page → app

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let route = ShellMessage.dispatch(message.body, handlers: config.handlers, page: self) { type, body in
            self.handleBuiltIn(type: type, body: body)
        }
        if case .unhandled(let type) = route { NSLog("%@: no handler for page message %@", config.appName, type) }
    }

    private func handleBuiltIn(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            let waiting = events.pageReady()
            matchPageBackground()
            deliverRemote()
            for event in waiting { deliver(event) }
        case "saveFile":
            if let name = body["name"] as? String, let base64 = body["base64"] as? String, let data = Data(base64Encoded: base64) {
                share(data, named: name)
            }
        case "log":
            NSLog("%@ page: %@", config.appName, body["text"] as? String ?? "")
        case "portal.pair":
            pair(origin: body["origin"] as? String)
        case "portal.signOut":
            signOut()
        default:
            // changed, pdf, new, open, save: the Mac's document messages. A
            // page shared with the Mac app may still post them; a phone has
            // no document to give them to.
            break
        }
    }

    // MARK: App → page

    /// `window.<name>Host.event(event)`, once the page is ready.
    func send(_ event: [String: Any]) {
        for ready in events.enqueue(event) { deliver(ready) }
    }

    private func deliver(_ event: [String: Any]) {
        guard let json = ShellEvent.json(event) else {
            NSLog("%@: event %@ is not JSON; not sent", config.appName, String(describing: event["type"] ?? "?"))
            return
        }
        webView.callAsyncJavaScript(ShellEvent.script(hostObject: config.hostObject), arguments: ["json": json],
                                    in: nil, in: .page) { _ in }
    }

    /// A URL the system opened the app with. A connect link finishes pairing;
    /// a link in the app's own scheme goes to the page.
    func open(_ url: URL) {
        if config.pairsWithPortal, ShellPortal.shared.handle(url) { return }
        if let event = config.openEvent(for: url) { send(event) } else { NSLog("%@: ignored %@", config.appName, url.absoluteString) }
    }

    // MARK: The Portal

    private func deliverRemote() {
        guard config.pairsWithPortal else { return }
        sendRemote(ShellPortal.remoteArguments(ShellPortal.shared.pairing))
    }

    /// `window.<name>Host.remote({url, token})`, as on the Mac.
    func sendRemote(_ arguments: [String: String]) {
        guard events.isReady else { return }   // the page gets it on `ready`
        webView.callAsyncJavaScript(PortalBridge.remoteScript(hostObject: config.hostObject),
                                    arguments: arguments, in: nil, in: .page) { _ in }
    }

    static func broadcastRemote(_ arguments: [String: String]) {
        for controller in live.allObjects { controller.sendRemote(arguments) }
    }

    private func pair(origin: String?) {
        guard config.pairsWithPortal else {
            NSLog("%@: portal.pair, but the app has no portalOrigin or connectScheme", config.appName)
            return
        }
        let portal = ShellPortal.shared
        if let origin, !origin.isEmpty { portal.origin = origin }
        guard !portal.origin.isEmpty else {
            alert(title: "No Portal address", message: "Type the address of the toolkit Portal, such as https://toolkit.example.")
            return
        }
        let label = UIDevice.current.name
        Task {
            do {
                _ = try await portal.pair(label: label)
            } catch PairingError.cancelled {
                // The person closed the sheet. Nothing to report.
            } catch {
                self.alert(title: "Could not sign in to the toolkit", message: error.localizedDescription)
            }
        }
    }

    private func signOut() {
        guard config.pairsWithPortal else { return }
        let portal = ShellPortal.shared
        Task {
            do {
                let result = try await portal.signOut()
                if result.wasPaired, !result.revoked {
                    self.alert(title: "Signed out on this iPhone",
                               message: "The Portal could not be reached, so its device token is still listed. Remove it from the Portal's Devices page when you are next online.")
                }
            } catch {
                self.alert(title: "Could not sign out", message: error.localizedDescription)
            }
        }
    }

    // MARK: Files

    /// The share sheet for bytes the page produced, which offers Save to Files,
    /// AirDrop, Mail and the rest. The file lives in a scratch folder only as
    /// long as the sheet is up.
    private func share(_ data: Data, named name: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent(ShellBridge.exportFileName(name))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            alert(title: "Could not export \(name)", message: error.localizedDescription)
            return
        }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: folder) }
        if let popover = sheet.popoverPresentationController {   // iPad
            popover.sourceView = webView
            popover.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        guard let presenter else { try? FileManager.default.removeItem(at: folder); return }
        presenter.present(sheet, animated: true)
    }

    // MARK: Presenting

    /// The view controller on top, which is the one that can present.
    private var presenter: UIViewController? {
        var top = webView.window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private func alert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter?.present(alert, animated: true)
    }

    // MARK: Navigation

    /// The view shows the app and nothing else; a link out opens in Safari
    /// (or Mail, or Phone).
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == config.scheme.lowercased() || scheme == "about" || scheme == "blob" || scheme == "data" {
            decisionHandler(.allow)
            return
        }
        if ["http", "https", "mailto", "tel", "sms"].contains(scheme) { UIApplication.shared.open(url) }
        decisionHandler(.cancel)
    }

    /// `window.open` and `target="_blank"`: out to Safari, never a second web view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
        }
        return nil
    }

    /// A new page (a reload) waits for its own `ready` before events go in.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        events.pageUnloaded()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        matchPageBackground()
    }

    private func matchPageBackground() {
        if let color = webView.underPageBackgroundColor { container.backgroundColor = color }
    }

    /// iOS kills a background web content process under memory pressure; the
    /// page comes back on its own rather than as a blank screen.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        events.pageUnloaded()
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("%@ page failed to load: %@", config.appName, error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("%@ page failed to load: %@", config.appName, error.localizedDescription)
    }

    // MARK: alert(), confirm(), prompt()

    // WKWebView shows none of these by itself; a page that calls confirm()
    // before deleting something would otherwise get `false` every time.

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter else { completionHandler(false); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let presenter else { completionHandler(nil); return }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text ?? "")
        })
        presenter.present(alert, animated: true)
    }
}
#endif
