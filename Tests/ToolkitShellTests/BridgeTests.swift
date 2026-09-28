import XCTest
@testable import ToolkitShell

/// The parts of the bridge both shells share: the config an iPhone app gives,
/// where a page message goes, how an event reaches the page, and where the
/// page's files come from. None of it needs a window, so it runs under
/// `swift test` on the Mac and proves the iOS half's logic as well.
final class BridgeTests: XCTestCase {
    /// Where an iPhone app's bundled web folder lives. Nothing here reads the
    /// disk, so the path only has to have the right shape.
    private let webRoot = URL(fileURLWithPath: "/var/containers/Bundle/Application/5F1C0D2E-0000-4000-8000-000000000000/Flow.app/web",
                              isDirectory: true)

    private var phoneConfig: ShellConfig {
        ShellConfig(appName: "Flow", handlerName: "flow", urlScheme: "flow", webRoot: webRoot)
    }

    // MARK: Config

    func testAnAppWithNoDocumentsNeedsOnlyItsNamesAndItsWebRoot() {
        let c = phoneConfig
        XCTAssertEqual(c.scheme, "flow-app", "the page's scheme follows the handler name")
        XCTAssertEqual(c.urlScheme, "flow")
        XCTAssertEqual(c.webRoot, webRoot)
        XCTAssertEqual(c.repositoryRoot, webRoot)
        XCTAssertEqual(c.fileSuffix, ".json")
        XCTAssertEqual(c.documentNoun, "document")
        XCTAssertEqual(c.untitledName, "Untitled document")
        XCTAssertEqual(c.importedTypes, [])
        XCTAssertTrue(c.handlers.isEmpty)
        XCTAssertFalse(c.pairsWithPortal)
        XCTAssertEqual(c.hostObject, "window.flowHost")
    }

    func testADocumentAppsConfigMeansWhatItAlwaysMeant() {
        let root = URL(fileURLWithPath: "/src/sysml")
        let c = ShellConfig(appName: "SysML Modeler", handlerName: "sysml", scheme: "sysml-app", fileSuffix: ".sysml.json",
                            documentNoun: "model", importedTypes: ["public.xml"], repositoryRoot: root,
                            portalOrigin: "https://toolkit.example")
        XCTAssertEqual(c.scheme, "sysml-app")
        XCTAssertEqual(c.untitledName, "Untitled model")
        XCTAssertEqual(c.repositoryRoot, root)
        XCTAssertEqual(c.webRoot, root, "a Mac app's web root is its repository until it is bundled")
        XCTAssertNil(c.urlScheme)
        XCTAssertEqual(c.connectScheme, "sysml")
    }

    func testTheWebRootDefaultsToTheBundlesWebFolder() {
        XCTAssertEqual(ShellConfig(appName: "X", handlerName: "x").webRoot.lastPathComponent, "web")
    }

    // MARK: Page → app

    @MainActor
    func testTypesTheShellDoesNotKnowGoToTheAppsHandlers() throws {
        let page = RecordingPage()
        let handlers: [String: ShellHandler] = [
            "echo": { message, page in page.send(["type": "echo", "text": message["text"] as? String ?? ""]) },
        ]
        var builtIns: [String] = []
        let route = ShellMessage.dispatch(["type": "echo", "text": "hello"], handlers: handlers, page: page) { type, _ in
            builtIns.append(type)
        }
        XCTAssertEqual(route, .handled("echo"))
        XCTAssertTrue(builtIns.isEmpty)
        XCTAssertEqual(page.sent.count, 1)
        XCTAssertEqual(page.sent.first?["type"] as? String, "echo")
        XCTAssertEqual(page.sent.first?["text"] as? String, "hello")

        XCTAssertEqual(ShellMessage.dispatch(["type": "nobody.listens"], handlers: handlers, page: page) { _, _ in },
                       .unhandled("nobody.listens"))
        XCTAssertEqual(page.sent.count, 1)
    }

    @MainActor
    func testBuiltInTypesNeverReachTheAppsHandlers() {
        let page = RecordingPage()
        // An app that names a handler after a built-in does not get to take it over.
        var handlers: [String: ShellHandler] = [:]
        for type in ShellMessage.builtInTypes {
            handlers[type] = { _, page in page.send(["type": "stolen"]) }
        }
        for type in ["ready", "saveFile", "log", "portal.pair", "portal.signOut", "changed", "pdf", "new", "open", "save"] {
            XCTAssertTrue(ShellMessage.builtInTypes.contains(type), type)
            var got: [String] = []
            let route = ShellMessage.dispatch(["type": type, "extra": 1], handlers: handlers, page: page) { t, body in
                got.append(t)
                XCTAssertEqual(body["extra"] as? Int, 1)
            }
            XCTAssertEqual(route, .builtIn(type))
            XCTAssertEqual(got, [type])
        }
        XCTAssertTrue(page.sent.isEmpty)
    }

    @MainActor
    func testAMessageWithNoTypeIsDropped() {
        let page = RecordingPage()
        var called = false
        XCTAssertEqual(ShellMessage.dispatch("ready", handlers: [:], page: page) { _, _ in called = true }, .malformed)
        XCTAssertEqual(ShellMessage.dispatch(["text": "x"], handlers: [:], page: page) { _, _ in called = true }, .malformed)
        XCTAssertFalse(called)
    }

    // MARK: App → page

    func testEventsTravelAsJSON() throws {
        XCTAssertEqual(ShellEvent.json(["type": "open", "url": "flow://task/42?start=1"]),
                       #"{"type":"open","url":"flow://task/42?start=1"}"#)

        let event: [String: Any] = ["type": "echo", "n": 3, "ok": true, "list": [1, "two"], "none": NSNull(),
                                    "nested": ["a": 1.5]]
        let json = try XCTUnwrap(ShellEvent.json(event))
        XCTAssertTrue(json.contains(#""ok":true"#), json)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(back["type"] as? String, "echo")
        XCTAssertEqual(back["n"] as? Int, 3)
        XCTAssertEqual((back["list"] as? [Any])?.count, 2)
        XCTAssertTrue(back["none"] is NSNull)
        XCTAssertEqual((back["nested"] as? [String: Any])?["a"] as? Double, 1.5)

        // A value JSON cannot carry is refused, not sent half-encoded.
        XCTAssertNil(ShellEvent.json(["type": "bad", "when": Date()]))
        XCTAssertNil(ShellEvent.json(["type": "bad", "url": URL(string: "flow://x")!]))
    }

    func testTheEventCallKeepsTheValuesOutOfTheScript() {
        let script = ShellEvent.script(hostObject: "window.flowHost")
        XCTAssertTrue(script.contains("window.flowHost"))
        XCTAssertTrue(script.contains(".event(JSON.parse(json))"))
        // A page with a host.js from before `event` must not throw.
        XCTAssertTrue(script.contains("typeof"))
    }

    func testEventsWaitForTheReadyPage() {
        var queue = ShellEventQueue()
        XCTAssertFalse(queue.isReady)
        XCTAssertTrue(queue.enqueue(["type": "open", "url": "flow://a"]).isEmpty)
        XCTAssertTrue(queue.enqueue(["type": "open", "url": "flow://b"]).isEmpty)
        XCTAssertEqual(queue.pageReady().compactMap { $0["url"] as? String }, ["flow://a", "flow://b"], "in order")
        XCTAssertTrue(queue.isReady)
        XCTAssertEqual(queue.enqueue(["type": "x"]).count, 1, "a ready page gets it at once")
        XCTAssertTrue(queue.pageReady().isEmpty, "nothing is delivered twice")

        queue.pageUnloaded()
        XCTAssertTrue(queue.enqueue(["type": "y"]).isEmpty, "a reloading page waits again")
        XCTAssertEqual(queue.pageReady().count, 1)
    }

    func testDeepLinksBecomeOpenEvents() {
        let event = phoneConfig.openEvent(for: URL(string: "flow://task/42?start=1")!)
        XCTAssertEqual(event?["type"] as? String, "open")
        XCTAssertEqual(event?["url"] as? String, "flow://task/42?start=1")
        XCTAssertNotNil(phoneConfig.openEvent(for: URL(string: "FLOW://today")!), "schemes ignore case")
        XCTAssertNil(phoneConfig.openEvent(for: URL(string: "https://toolkit.example/flow")!))
        XCTAssertNil(ShellConfig(appName: "X", handlerName: "x", webRoot: webRoot).openEvent(for: URL(string: "x://y")!),
                     "no urlScheme, no deep links")
    }

    func testThePageIsToldItsHandlerAndPlatform() {
        let ios = ShellBridge.bootstrapScript(handlerName: "flow", platform: .ios)
        XCTAssertTrue(ios.contains("window.__toolkitHost = 'flow';"))
        XCTAssertTrue(ios.contains("window.__toolkitPlatform = 'ios';"))
        XCTAssertTrue(ios.contains("webkit.messageHandlers.flow.postMessage"), "page errors still reach the log")
        let mac = ShellBridge.bootstrapScript(handlerName: "sysml", platform: .macos)
        XCTAssertTrue(mac.contains("window.__toolkitPlatform = 'macos';"))
        #if os(macOS)
        XCTAssertEqual(ShellPlatform.current, .macos)
        #else
        XCTAssertEqual(ShellPlatform.current, .ios)
        #endif
    }

    func testAnExportsNameCannotLeaveItsFolder() {
        XCTAssertEqual(ShellBridge.exportFileName("week.csv"), "week.csv")
        XCTAssertEqual(ShellBridge.exportFileName("a/b:c.csv"), "a-b-c.csv")
        XCTAssertEqual(ShellBridge.exportFileName(".hidden"), "hidden")
        XCTAssertEqual(ShellBridge.exportFileName("  "), "export")
        XCTAssertFalse(ShellBridge.exportFileName("../../etc/passwd").contains("/"))
    }

    // MARK: WebRoot

    func testAnIPhoneAppServesItsBundledWebFolder() throws {
        let c = phoneConfig
        XCTAssertEqual(WebRoot.directory(for: c, bundledWeb: nil, platform: .ios), webRoot)
        XCTAssertEqual(WebRoot.directory(for: c, bundledWeb: URL(fileURLWithPath: "/elsewhere/web"), platform: .ios), webRoot,
                       "the configured folder, never a guess")
        XCTAssertEqual(WebRoot.indexURL(scheme: c.scheme).absoluteString, "flow-app://app/index.html")

        // Bundle.url(forResource: "web", withExtension: nil) hands back a directory URL with a trailing slash.
        let slashed = URL(fileURLWithPath: webRoot.path + "/", isDirectory: true)
        for root in [webRoot, slashed] {
            let index = try XCTUnwrap(WebRoot.file(for: URL(string: "flow-app://app/")!, under: root))
            XCTAssertTrue(index.path.hasSuffix("/Flow.app/web/index.html"), index.path)
            let module = try XCTUnwrap(WebRoot.file(for: URL(string: "flow-app://app/src/main.js")!, under: root))
            XCTAssertTrue(module.path.hasSuffix("/Flow.app/web/src/main.js"), module.path)
            let font = try XCTUnwrap(WebRoot.file(for: URL(string: "flow-app://app/fonts/Exo%202.woff2")!, under: root))
            XCTAssertTrue(font.path.hasSuffix("/Flow.app/web/fonts/Exo 2.woff2"), font.path)

            XCTAssertNil(WebRoot.file(for: URL(string: "flow-app://app/../Info.plist")!, under: root))
            XCTAssertNil(WebRoot.file(for: URL(string: "flow-app://app/src/../../Flow")!, under: root))
            XCTAssertNil(WebRoot.file(for: URL(string: "flow-app://app/../web-private/key")!, under: root),
                         "a sibling whose name starts with the root's is still outside it")
        }
        XCTAssertEqual(WebRoot.mimeType(for: webRoot.appendingPathComponent("src/main.mjs")), "text/javascript")
        XCTAssertEqual(WebRoot.contentType(for: webRoot.appendingPathComponent("index.html")), "text/html; charset=utf-8")
    }

    func testAMacAppStillPrefersItsBundledCopy() throws {
        let repo = URL(fileURLWithPath: "/src/app")
        let c = ShellConfig(appName: "App", handlerName: "app", scheme: "app-app", fileSuffix: ".app.json",
                            documentNoun: "model", repositoryRoot: repo)
        XCTAssertEqual(WebRoot.directory(for: c, bundledWeb: nil, platform: .macos), repo)
        XCTAssertEqual(WebRoot.directory(for: c, bundledWeb: URL(fileURLWithPath: "/nonexistent/web"), platform: .macos), repo,
                       "a Resources/web with no index.html is not a web root")

        let bundled = FileManager.default.temporaryDirectory.appendingPathComponent("shell-kit-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundled) }
        try Data("<!doctype html>".utf8).write(to: bundled.appendingPathComponent("index.html"))
        XCTAssertEqual(WebRoot.directory(for: c, bundledWeb: bundled, platform: .macos), bundled)
    }
}

/// A page that keeps what the shell sent it.
@MainActor
private final class RecordingPage: ShellPage {
    var sent: [[String: Any]] = []
    func send(_ event: [String: Any]) { sent.append(event) }
}
