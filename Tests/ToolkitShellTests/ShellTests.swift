import XCTest
@testable import ToolkitShell

// The Mac shell's own tests: menus, documents, the app delegate, and the
// build scripts they run through Process. `swift test` runs on macOS only.
#if os(macOS)

final class ShellTests: XCTestCase {
    /// The kit's own repository root, from …/Tests/ToolkitShellTests/ShellTests.swift.
    private var kitRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUp() {
        ShellConfig.current = ShellConfig(appName: "Test App", handlerName: "test", scheme: "test-app", fileSuffix: ".test.json",
                                          documentNoun: "model", importedTypes: ["public.xml"], repositoryRoot: kitRoot)
    }

    func testConfigDerivedNames() {
        let c = ShellConfig.current
        XCTAssertEqual(c.hostObject, "window.testHost")
        XCTAssertEqual(c.untitledName, "Untitled model")
        XCTAssertEqual(c.defaultPDFName, "test.pdf")
        XCTAssertEqual(WebRoot.indexURL.absoluteString, "test-app://app/index.html")
    }

    func testSaveNameMatchesTheWebApps() {
        XCTAssertEqual(WebDocument.fileName(forModelNamed: "Vehicle model"), "vehicle-model.test.json")
        XCTAssertEqual(WebDocument.fileName(forModelNamed: "  Pump / v2 (draft) ", suffix: ".x.json"), "pump-v2-draft.x.json")
        XCTAssertEqual(WebDocument.fileName(forModelNamed: "…"), "untitled.test.json")
    }

    func testXMLIsToldFromJSON() {
        XCTAssertTrue(WebDocument.looksLikeXML("\u{FEFF}\n <?xml version=\"1.0\"?><x/>"))
        XCTAssertFalse(WebDocument.looksLikeXML("  {\"format\":\"x\"}"))
    }

    func testTheSchemeServesOnlyTheWebRoot() throws {
        let root = kitRoot
        let index = try XCTUnwrap(WebRoot.file(for: URL(string: "test-app://app/")!, under: root))
        XCTAssertEqual(index.lastPathComponent, "index.html")
        XCTAssertNotNil(WebRoot.file(for: URL(string: "test-app://app/js/host.js")!, under: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("js/host.js").path))
        XCTAssertNil(WebRoot.file(for: URL(string: "test-app://app/../other/index.html")!, under: root))
        XCTAssertNil(WebRoot.file(for: URL(string: "test-app://app/js/../../secret")!, under: root))
    }

    func testContentTypes() {
        XCTAssertEqual(WebRoot.mimeType(for: URL(fileURLWithPath: "/x/main.js")), "text/javascript")
        XCTAssertEqual(WebRoot.contentType(for: URL(fileURLWithPath: "/x/kit.css")), "text/css; charset=utf-8")
        XCTAssertEqual(WebRoot.contentType(for: URL(fileURLWithPath: "/x/exo.woff2")), "font/woff2")
    }

    func testMenuHelpers() {
        let bar = ShellMenu.mainMenu(
            appMenuExtras: [ShellMenu.web("Appearance…", "view.appearance", ",")],
            menus: [ShellMenu.submenu("File", ShellMenu.documentItems() + [.separator()] + ShellMenu.saveItems() + [ShellMenu.web("Sample", "file.sample")]),
                    ShellMenu.submenu("Edit", ShellMenu.editItems())],
            helpItems: [ShellMenu.web("Guide", "help.guide", "?")])
        XCTAssertEqual(bar.items.map(\.title), ["Test App", "File", "Edit", "Window", "Help"])
        XCTAssertEqual(Set(ShellMenu.webCommandIDs(in: bar)), ["view.appearance", "file.sample", "edit.undo", "edit.redo", "edit.selectAll", "help.guide"])
        XCTAssertEqual(bar.items[0].submenu?.items.first?.title, "About Test App")
        XCTAssertNotNil(bar.items[1].submenu?.items.first { $0.title == "Open Recent" }?.submenu)
    }

    func testCommandTableParsing() {
        let js = """
        const x = 1;
        export const COMMANDS = {
          'file.new': newModel, 'file.open': openFile,
          'export.pdfAll': exportAllPdf,
          'help.guide': help,
        };
        const y = 2;
        """
        XCTAssertEqual(ShellMenu.commandIDs(inJavaScript: js), ["file.new", "file.open", "export.pdfAll", "help.guide"])
    }
}
#endif
