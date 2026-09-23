import AppKit
import WebKit
import UniformTypeIdentifiers

/// A document window: a web view showing the app, and the message channel
/// between the page and the document. `js/host.js` is the page's half.
///
/// Subclass and override `handleMessage` to answer messages the kit does not
/// know (an app-specific export, say); return true when you took it.
open class EditorWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate {
    public private(set) var webView: WKWebView!
    public private(set) var pageReady = false
    private var pdfExporter: PDFExporter?
    private let config = ShellConfig.current

    public var webDocument: WebDocument? { document as? WebDocument }

    public init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = config.minimumWindowSize
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.04, green: 0.06, blue: 0.09, alpha: 1)
        window.tabbingMode = .preferred
        window.setFrameAutosaveName(config.windowFrameAutosaveName)
        window.center()
        super.init(window: window)
        shouldCascadeWindows = true

        let name = config.handlerName
        let wk = WKWebViewConfiguration()
        wk.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: config.scheme)
        wk.userContentController.add(WeakMessageHandler(self), name: name)
        // Tell the page which handler it is talking to, before any of its modules load;
        // and route page errors, which would otherwise vanish, to the app's log.
        wk.userContentController.addUserScript(WKUserScript(source: """
            window.__toolkitHost = '\(name)';
            window.addEventListener('error', (e) => webkit.messageHandlers.\(name).postMessage({ type: 'log', text: String(e.message) + ' @ ' + e.filename + ':' + e.lineno }));
            window.addEventListener('unhandledrejection', (e) => webkit.messageHandlers.\(name).postMessage({ type: 'log', text: 'unhandled: ' + String(e.reason) }));
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: window.contentLayoutRect, configuration: wk)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
        window.contentView = webView
        window.initialFirstResponder = webView
        webView.load(URLRequest(url: WebRoot.indexURL))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Page → app

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if handleMessage(type: type, body: body) { return }
        switch type {
        case "ready":
            pageReady = true
            deliverPendingText()
        case "changed":
            if let json = body["json"] as? String {
                webDocument?.pageDidChange(json: json, dirty: body["dirty"] as? Bool ?? false, name: body["name"] as? String ?? config.untitledName)
            }
        case "saveFile":
            if let name = body["name"] as? String, let base64 = body["base64"] as? String, let data = Data(base64Encoded: base64) {
                saveExport(data, suggestedName: name)
            }
        case "pdf":
            exportPDF(body)
        case "new": NSDocumentController.shared.newDocument(nil)
        case "open": NSDocumentController.shared.openDocument(nil)
        case "save": webDocument?.save(nil)
        case "log": NSLog("%@ page: %@", config.appName, body["text"] as? String ?? "")
        default: break
        }
    }

    /// App-specific messages. The default takes none.
    open func handleMessage(type: String, body: [String: Any]) -> Bool { false }

    // MARK: App → page

    /// Give the page the text the document read, once both exist.
    public func deliverPendingText() {
        guard pageReady, let doc = webDocument, let text = doc.pendingText else { return }
        let name = doc.pendingName ?? ""
        webView.callAsyncJavaScript("return \(config.hostObject).load(text, name)", arguments: ["text": text, "name": name],
                                    in: nil, in: .page) { [weak doc] _ in
            doc?.didDeliverPendingText()
        }
    }

    public func documentWasSaved(as fileName: String) {
        webView.callAsyncJavaScript("\(config.hostObject).saved(name)", arguments: ["name": fileName], in: nil, in: .page) { _ in }
    }

    /// Menu items carry a web command id as their represented object.
    @objc public func runWebCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        window?.makeFirstResponder(webView)
        webView.callAsyncJavaScript("\(config.hostObject).command(id)", arguments: ["id": id], in: nil, in: .page) { _ in }
    }

    @objc open func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(runWebCommand(_:)) ? pageReady : true
    }

    // MARK: Exports

    /// A save panel for bytes the page produced (SVG, PNG, XMI, CSV…).
    public func saveExport(_ data: Data, suggestedName: String) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        if let type = UTType(filenameExtension: (suggestedName as NSString).pathExtension) { panel.allowedContentTypes = [type] }
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    public func presentError(_ error: Error) {
        if let window { NSAlert(error: error).beginSheetModal(for: window) }
    }

    private func exportPDF(_ body: [String: Any]) {
        let pages = (body["pages"] as? [[String: Any]] ?? []).compactMap { page -> PDFExporter.Page? in
            guard let svg = page["svg"] as? String, let w = page["w"] as? Double, let h = page["h"] as? Double else { return nil }
            return PDFExporter.Page(svg: svg, size: CGSize(width: w, height: h))
        }
        guard !pages.isEmpty else { return }
        let name = body["name"] as? String ?? config.defaultPDFName
        let exporter = PDFExporter(pages: pages)
        pdfExporter = exporter
        exporter.run { [weak self] data in
            self?.pdfExporter = nil
            if let data { self?.saveExport(data, suggestedName: name) }
        }
    }

    // MARK: Navigation

    /// The window shows the app and nothing else; a link out opens in the browser.
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == config.scheme || url.scheme == "about" { decisionHandler(.allow); return }
        if url.scheme == "http" || url.scheme == "https" { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("%@ page failed to load: %@", config.appName, error.localizedDescription)
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("%@ page failed to load: %@", config.appName, error.localizedDescription)
    }
}

/// `WKUserContentController` retains its handlers; this keeps the window controller out of that cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
