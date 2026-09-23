import AppKit

/// Menu-bar building blocks. Document commands (New, Open, Save, Revert,
/// Close) are AppKit's own; everything about the model is a *web command id*
/// that the front window's `EditorWindowController.runWebCommand` hands to the
/// page — the same ids the web app's own menu bar runs.
///
/// An app assembles its bar from these:
///
///     let bar = ShellMenu.mainMenu(
///         appMenuExtras: [ShellMenu.web("Appearance…", "view.appearance", ",")],
///         menus: [ShellMenu.submenu("File", […]), ShellMenu.submenu("Edit", […]), …],
///         helpItems: [ShellMenu.web("Working with the Modeler", "help.guide", "?")])
public enum ShellMenu {
    /// The whole bar: app menu, the app's own menus, then Window and Help, registered with NSApp.
    public static func mainMenu(appMenuExtras: [NSMenuItem] = [], menus: [NSMenuItem], helpItems: [NSMenuItem] = []) -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenu(extras: appMenuExtras))
        menus.forEach(main.addItem)
        let window = windowMenu()
        main.addItem(window)
        NSApplication.shared.windowsMenu = window.submenu
        let help = submenu("Help", helpItems)
        main.addItem(help)
        NSApplication.shared.helpMenu = help.submenu
        return main
    }

    public static func appMenu(extras: [NSMenuItem] = []) -> NSMenuItem {
        let name = ShellConfig.current.appName
        var items: [NSMenuItem] = [item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))]
        if !extras.isEmpty { items += [.separator()] + extras }
        items += [
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ]
        return submenu(name, items)
    }

    /// New, Open, Open Recent, Close, Save, Save As, Revert — the document half of a File menu.
    public static func documentItems() -> [NSMenuItem] {
        [item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
         item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
         recentMenu()]
    }
    public static func saveItems() -> [NSMenuItem] {
        [item("Close", #selector(NSWindow.performClose(_:)), "w"),
         item("Save…", #selector(NSDocument.save(_:)), "s"),
         item("Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]),
         item("Revert to Saved", #selector(NSDocument.revertToSaved(_:)))]
    }
    /// Cut, Copy, Paste for text fields, with undo / redo / select-all sent to the page.
    public static func editItems(selectAllTitle: String = "Select All") -> [NSMenuItem] {
        [web("Undo", "edit.undo", "z"),
         web("Redo", "edit.redo", "z", [.command, .shift]),
         .separator(),
         item("Cut", #selector(NSText.cut(_:)), "x"),
         item("Copy", #selector(NSText.copy(_:)), "c"),
         item("Paste", #selector(NSText.paste(_:)), "v"),
         web(selectAllTitle, "edit.selectAll", "a")]
    }
    public static func fullScreenItem() -> NSMenuItem {
        item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
    }
    public static func windowMenu() -> NSMenuItem {
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
    }

    /// A menu item with an AppKit action.
    public static func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        return it
    }

    /// A menu item that runs a web command in the front window's page.
    public static func web(_ title: String, _ id: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let it = item(title, #selector(EditorWindowController.runWebCommand(_:)), key, mods)
        it.representedObject = id
        return it
    }

    public static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        holder.submenu = menu
        return holder
    }

    public static func recentMenu() -> NSMenuItem {
        let holder = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Open Recent")
        // AppKit fills a menu with this private-but-stable name from the recent documents list.
        let setName = NSSelectorFromString("_setMenuName:")
        if menu.responds(to: setName) { menu.perform(setName, with: "NSRecentDocumentsMenu") }
        menu.addItem(item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:))))
        holder.submenu = menu
        return holder
    }

    /// Every web command id a menu can send — for the test that checks them against the page.
    public static func webCommandIDs(in menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            var ids = item.submenu.map { webCommandIDs(in: $0) } ?? []
            if item.action == #selector(EditorWindowController.runWebCommand(_:)), let id = item.representedObject as? String { ids.append(id) }
            return ids
        }
    }

    /// The command ids a page's `export const COMMANDS = { 'file.new': …, };` table declares.
    public static func commandIDs(inJavaScript source: String) -> Set<String> {
        guard let start = source.range(of: "export const COMMANDS = {"),
              let end = source.range(of: "\n};", range: start.upperBound..<source.endIndex) else { return [] }
        let table = source[start.upperBound..<end.lowerBound]
        return Set(table.matches(of: #/'([a-z]+\.[A-Za-z]+)':/#).map { String($0.1) })
    }
}

/// A minimal application delegate for a document-based shell app.
open class ShellAppDelegate: NSObject, NSApplicationDelegate {
    public override init() {}
    open func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    open func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

public enum ShellApp {
    /// Configure, build the bar with `menu`, and run. Never returns.
    public static func run(config: ShellConfig, delegate: NSApplicationDelegate = ShellAppDelegate(), menu: () -> NSMenu) -> Never {
        ShellConfig.current = config
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.mainMenu = menu()
        app.run()
        exit(0)
    }
}
