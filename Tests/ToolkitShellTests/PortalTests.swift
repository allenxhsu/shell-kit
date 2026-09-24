import XCTest
import SyncKit
@testable import ToolkitShell

/// Pairing with the Portal: the three places it can silently not work.
///
/// A scheme the bundle does not register, a `remote` the page's half of the
/// bridge does not expose, and a Keychain item that does not come back — each
/// of them leaves an app that compiles, opens its sign-in sheet, signs the
/// person in and then does nothing at all.
final class PortalTests: XCTestCase {
    private var kitRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The config of an app that has opted in to pairing.
    private func pairingConfig(origin: String? = "https://toolkit.example", scheme: String? = nil) -> ShellConfig {
        ShellConfig(appName: "Test App", handlerName: "test", scheme: "test-app", fileSuffix: ".test.json",
                    documentNoun: "model", repositoryRoot: kitRoot, portalOrigin: origin, connectScheme: scheme)
    }

    override func setUp() {
        ShellConfig.current = pairingConfig()
    }

    // MARK: Opting in

    func testAnAppWithoutAPortalIsUntouched() {
        ShellConfig.current = ShellConfig(appName: "Test App", handlerName: "test", scheme: "test-app",
                                          fileSuffix: ".test.json", documentNoun: "model", repositoryRoot: kitRoot)
        XCTAssertNil(ShellConfig.current.connectScheme)
        XCTAssertFalse(ShellConfig.current.pairsWithPortal)
        XCTAssertTrue(ShellMenu.portalItems().isEmpty, "no Portal, no menu items")
        // With no method to call, AppKit keeps its own document-opening path —
        // which is the whole of "existing apps build unchanged".
        XCTAssertFalse(ShellAppDelegate().responds(to: #selector(ShellAppDelegate.application(_:open:))))
    }

    func testTheConnectSchemeFollowsTheHandlerName() {
        XCTAssertEqual(pairingConfig().connectScheme, "test")
        XCTAssertEqual(pairingConfig(scheme: "test-connect").connectScheme, "test-connect")
        // A Portal the person supplies later: no default origin, but the app
        // still says which scheme its bundle claims.
        XCTAssertEqual(pairingConfig(origin: nil, scheme: "test").connectScheme, "test")
        XCTAssertTrue(ShellAppDelegate().responds(to: #selector(ShellAppDelegate.application(_:open:))))
    }

    func testThePortalItemsAreTheStandardTwo() {
        let extras = [ShellMenu.web("Appearance…", "view.appearance", ",")] + ShellMenu.portalItems()
        let bar = ShellMenu.mainMenu(appMenuExtras: extras, menus: [ShellMenu.submenu("File", ShellMenu.documentItems())])
        let appMenu = try? XCTUnwrap(bar.items.first?.submenu)
        let titles = appMenu?.items.map(\.title) ?? []
        XCTAssertEqual(titles.filter { $0.hasPrefix("Sign") }, ["Sign in to the toolkit…", "Sign out"])
        let signOut = appMenu?.items.first { $0.title == "Sign out" }
        XCTAssertEqual(signOut?.action, #selector(ShellPortal.signOutOfToolkit(_:)))
        XCTAssertTrue(signOut?.target is ShellPortal, "the items work with no document open, so they are not the window's")
        // Nothing here is a web command, so the page's COMMANDS table is unaffected.
        XCTAssertEqual(Set(ShellMenu.webCommandIDs(in: bar)), ["view.appearance"])
    }

    // MARK: The URL type

    /// The scheme has to be in the built bundle or the callback never arrives,
    /// so this runs the script an app's build script runs and reads the result
    /// back the way Launch Services would.
    func testTheBuildScriptRegistersTheConnectScheme() throws {
        let block = try runURLTypes(["test", "Test App"])
        let plist = plistAround(block)
        XCTAssertTrue(ShellPlist.declares(scheme: "test", inPlist: plist))
        XCTAssertTrue(ShellPlist.declares(scheme: "TEST", inPlist: plist), "Launch Services ignores case")
        XCTAssertFalse(ShellPlist.declares(scheme: "pyramid", inPlist: plist))
        XCTAssertEqual(ShellPlist.urlSchemes(inPlist: plist), ["test"])

        // A plist with no URL types at all is what every app has today.
        XCTAssertTrue(ShellPlist.urlSchemes(inPlist: plistAround("")).isEmpty)
        XCTAssertTrue(ShellPlist.urlSchemes(inPlist: Data("not a plist".utf8)).isEmpty)
    }

    func testTheBuildScriptCatchesABundleThatForgotTheScheme() throws {
        let registered = FileManager.default.temporaryDirectory.appendingPathComponent("with-\(UUID().uuidString).plist")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("without-\(UUID().uuidString).plist")
        try plistAround(try runURLTypes(["test", "Test App"])).write(to: registered)
        try plistAround("").write(to: missing)
        defer { try? FileManager.default.removeItem(at: registered); try? FileManager.default.removeItem(at: missing) }

        XCTAssertEqual(try runURLTypesStatus(["--check", registered.path, "test"]), 0)
        XCTAssertEqual(try runURLTypesStatus(["--check", missing.path, "test"]), 1,
                       "a build that forgot the URL type has to fail loudly, not ship")
        // A scheme Launch Services would never match is a usage error, not a
        // plist nobody notices is dead.
        XCTAssertEqual(try runURLTypesStatus(["Not A Scheme"]), 2)
    }

    // MARK: The bridge message

    func testTheRemoteMessageIsWhatThePageExposes() throws {
        XCTAssertEqual(PortalBridge.remoteScript(hostObject: ShellConfig.current.hostObject),
                       "window.testHost.remote({ url, token })")
        // The values travel as arguments, never interpolated into the script:
        // a token is not something to put through a JavaScript parser.
        XCTAssertFalse(PortalBridge.remoteScript(hostObject: "window.testHost").contains("http"))

        let host = try String(contentsOf: kitRoot.appendingPathComponent("js/host.js"), encoding: .utf8)
        let exposed = PortalBridge.hostAPINames(inJavaScript: host)
        XCTAssertEqual(exposed, ["load", "command", "saved", "remote"],
                       "the shell calls remote on every page; js/host.js has to expose it")
    }

    func testTheRemoteMessageCarriesTheSyncSettings() {
        let paired = DevicePairing(url: "https://toolkit.example", token: "t0ken", deviceId: "dev-1")
        XCTAssertEqual(ShellPortal.remoteArguments(paired), ["url": "https://toolkit.example", "token": "t0ken"])
        // Signed out: the same two fields, emptied, which is what clearing
        // them in the page's own Sync settings does.
        XCTAssertEqual(ShellPortal.remoteArguments(nil), ["url": "", "token": ""])
    }

    // MARK: The Keychain, end to end

    func testPairingKeepsTheTokenAndTellsThePage() async throws {
        let service = "shell-kit.test.\(UUID().uuidString)"
        let store = KeychainPairingStore(service: service)
        do {
            try store.save(DevicePairing(url: "https://probe.example", token: "probe"))
        } catch let error as PairingError {
            throw XCTSkip("no usable Keychain here: \(error.localizedDescription)")
        }
        defer { try? store.forget() }

        let sent = Recorder()
        let portal = ShellPortal(config: pairingConfig(), defaults: try scratchDefaults(), store: store,
                                 present: fakePairingSheet(token: "t0ken"), deliver: sent.record)

        let paired = try await portal.pair(label: "Test Mac")
        XCTAssertEqual(paired.url, "https://toolkit.example")
        XCTAssertEqual(paired.token, "t0ken")
        XCTAssertEqual(sent.messages, [["url": "https://toolkit.example", "token": "t0ken"]],
                       "the page is told as soon as the shell has the pair")

        // A second launch: a new portal over the same Keychain item, no sheet.
        let relaunched = ShellPortal(config: pairingConfig(), defaults: try scratchDefaults(), store: store,
                                     deliver: { _ in })
        XCTAssertTrue(relaunched.isPaired)
        XCTAssertEqual(relaunched.pairing, paired)

        // Signing out forgets it and empties the page's settings. The Portal
        // is not there to be asked, which must not stop either half.
        let result = try await portal.signOut()
        XCTAssertTrue(result.wasPaired)
        XCTAssertFalse(portal.isPaired)
        XCTAssertNil(relaunched.pairing)
        XCTAssertEqual(sent.messages.last, ["url": "", "token": ""])
    }

    func testACallbackFromTheAppDelegateIsAcceptedOrPassedOn() throws {
        let sent = Recorder()
        let portal = ShellPortal(config: pairingConfig(), defaults: try scratchDefaults(),
                                 store: MemoryPairingStore(), deliver: sent.record)

        XCTAssertTrue(portal.handle(URL(string: "test://connect?url=https%3A%2F%2Ftoolkit.example&token=t&device=d1")!))
        XCTAssertEqual(portal.pairing?.deviceId, "d1")
        XCTAssertEqual(sent.messages.last, ["url": "https://toolkit.example", "token": "t"])

        // Anything else belongs to whoever else is listening — a document the
        // Finder is opening, most of all.
        XCTAssertFalse(portal.handle(URL(fileURLWithPath: "/tmp/model.test.json")))
        XCTAssertFalse(portal.handle(URL(string: "pyramid://connect?url=https%3A%2F%2Fa.example&token=t")!))
        XCTAssertFalse(portal.handle(URL(string: "test://connect?url=https%3A%2F%2Fa.example%2Fsteal&token=t")!),
                       "a url that is not a bare origin is a redirect someone smuggled in")
        XCTAssertEqual(portal.pairing?.token, "t", "a refused link never replaces a working pairing")
    }

    func testThePersonsPortalAddressWinsOverTheAppsDefault() throws {
        let defaults = try scratchDefaults()
        let portal = ShellPortal(config: pairingConfig(), defaults: defaults, store: MemoryPairingStore(), deliver: { _ in })
        XCTAssertEqual(portal.origin, "https://toolkit.example")

        portal.origin = "http://192.168.1.5:8080/"
        XCTAssertEqual(portal.origin, "http://192.168.1.5:8080", "a trailing slash would double up in every route")
        XCTAssertEqual(ShellPortal(config: pairingConfig(), defaults: defaults, store: MemoryPairingStore(),
                                   deliver: { _ in }).origin,
                       "http://192.168.1.5:8080", "the change outlives the launch that made it")

        // Emptying the field means "forget my change", not "no Portal".
        portal.origin = "  "
        XCTAssertEqual(portal.origin, "https://toolkit.example")
    }

    // MARK: Helpers

    /// A sign-in sheet that never opens: the link the Portal would have
    /// redirected to, handed straight back.
    private func fakePairingSheet(token: String, device: String? = "dev-1") -> PairingFlow.Present {
        { page, scheme in
            XCTAssertEqual(page.path, "/devices/pair")
            let query = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "scheme" }?.value, scheme)
            XCTAssertEqual(query.first { $0.name == "label" }?.value, "Test Mac")
            return URL(string: ConnectLink.build(scheme: scheme, origin: "https://toolkit.example",
                                                 token: token, deviceId: device))!
        }
    }

    private func scratchDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "shell-kit.test.\(UUID().uuidString)"))
    }

    private func plistAround(_ block: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleName</key><string>Test App</string>
        \(block)
        </dict>
        </plist>
        """.utf8)
    }

    private func runURLTypes(_ arguments: [String]) throws -> String {
        let (status, output) = try node(arguments)
        XCTAssertEqual(status, 0, output)
        return output
    }

    private func runURLTypesStatus(_ arguments: [String]) throws -> Int32 {
        try node(arguments).status
    }

    /// The script an app's build script calls. Node is already a requirement
    /// of the kit (`copy-into.mjs`), but a machine without it should say so
    /// rather than fail.
    private func node(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", kitRoot.appendingPathComponent("scripts/url-types.mjs").path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { throw XCTSkip("node is not available: \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 127 { throw XCTSkip("node is not available") }
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// What the shell sent the page, in order.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [[String: String]] = []

    var messages: [[String: String]] { lock.withLock { sent } }
    func record(_ message: [String: String]) { lock.withLock { sent.append(message) } }
}
