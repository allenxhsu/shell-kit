#if os(macOS)
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
    /// "Sign in to the toolkit…" and "Sign out", for `appMenuExtras`.
    ///
    /// Empty unless the app set a `connectScheme` (which `portalOrigin` does
    /// for it), so an app that has not opted in gets no items, no separator
    /// and no change to the bar it has today:
    ///
    ///     appMenuExtras: [ShellMenu.web("Appearance…", "view.appearance", ",")] + ShellMenu.portalItems()
    ///
    /// The first item opens the Sync sheet — the Portal's address lives there,
    /// so a person can point the app at a different one — and the sheet starts
    /// the sign-in. "Sign out" is disabled until there is something to sign
    /// out of.
    public static func portalItems() -> [NSMenuItem] {
        guard ShellConfig.current.pairsWithPortal else { return [] }
        let portal = ShellPortal.shared
        let signIn = item("Sign in to the toolkit…", #selector(ShellPortal.showSyncSheet(_:)))
        let signOut = item("Sign out", #selector(ShellPortal.signOutOfToolkit(_:)))
        // A target of its own: these do not belong to the front window, and
        // "Sign out" has to stay alive when no document is open at all.
        for entry in [signIn, signOut] { entry.target = portal }
        return [signIn, signOut]
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

    /// Where a pairing callback lands: Launch Services routes
    /// `<connect scheme>://connect?url=…&token=…` here.
    ///
    /// `ASWebAuthenticationSession` usually hands the redirect straight back
    /// to the flow that opened it, and then this never runs. It runs for the
    /// cases where that session is gone — the person finished signing in after
    /// it timed out, or opened a connect link from the Portal in their own
    /// browser — which is exactly when the app most needs to accept it.
    open func application(_ application: NSApplication, open urls: [URL]) {
        let others = urls.filter { !ShellPortal.shared.handle($0) }
        // AppKit stops opening documents itself the moment a delegate
        // implements this method, so every URL that is not ours has to be
        // handed on by hand or the app quietly stops opening files.
        for url in others where url.isFileURL {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSDocumentController.shared.presentError(error) }
            }
        }
        // A deep link in the app's `urlScheme` goes to the front window's page
        // as `event({ type: 'open', url })`.
        for url in others where !url.isFileURL {
            guard let event = ShellConfig.current.openEvent(for: url) else { continue }
            let editors = NSDocumentController.shared.documents.flatMap(\.windowControllers)
                .compactMap { $0 as? EditorWindowController }
            let front = editors.first { $0.window?.isMainWindow == true } ?? editors.first
            if let front { front.send(event) } else { NSLog("%@: no window for %@", ShellConfig.current.appName, url.absoluteString) }
        }
    }

    /// An app that neither pairs nor takes deep links should behave exactly as
    /// it did before that method existed. Hiding the selector is how: with no
    /// delegate method to call, AppKit keeps its own document-opening path, untouched.
    open override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(application(_:open:)) {
            return ShellConfig.isConfigured && (ShellConfig.current.pairsWithPortal || ShellConfig.current.urlScheme != nil)
        }
        return super.responds(to: selector)
    }
}

/// The Mac entry point. The iPhone's is `ShellScene`.
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
#endif
