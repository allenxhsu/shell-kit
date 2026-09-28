// Pairing Sample — the smallest app the kit can host, and the one the kit's
// own "does pairing actually work" check drives.
//
//   node scripts/dev-portal.mjs &          # a stand-in for ../Portal
//   scripts/build-sample-app.sh            # → build/Pairing Sample.app
//   open "build/Pairing Sample.app"
//
// Everything here is what README's "Adopting it" describes: a config, an empty
// document subclass, and a menu table. Pairing adds one argument —
// `portalOrigin:` — and one entry in the app menu, `ShellMenu.portalItems()`.
// Examples/ios-sample is the same page in the iPhone shell.
import AppKit
import ToolkitShell

final class NoteDocument: WebDocument {}

// …/Sources/PairingSample/main.swift → the kit root, then the sample's page.
// Unbundled (`swift run PairingSample`) the scheme handler serves the page
// from here; the built bundle serves its own copy under Contents/Resources.
let web = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Examples/sample-web")

// The Portal the sheet opens. A default the person can change in the Sync
// sheet, so pointing the sample at a real deployment needs no rebuild.
let portal = ProcessInfo.processInfo.environment["PORTAL_ORIGIN"] ?? "http://127.0.0.1:7788"

// One app-specific message, the same one the iPhone sample handles: the page
// posts `{ type: 'echo', text }` and gets `event({ type: 'echo', text, platform })` back.
let echo: ShellHandler = { message, page in
    page.send(["type": "echo", "text": message["text"] as? String ?? "", "platform": "macos"])
}

ShellApp.run(config: ShellConfig(appName: "Pairing Sample", handlerName: "sample", scheme: "sample-app",
                                 fileSuffix: ".sample.json", documentNoun: "note",
                                 repositoryRoot: web, portalOrigin: portal, handlers: ["echo": echo])) {
    ShellMenu.mainMenu(
        appMenuExtras: ShellMenu.portalItems(),
        menus: [
            ShellMenu.submenu("File", ShellMenu.documentItems() + [.separator()] + ShellMenu.saveItems()),
            ShellMenu.submenu("Edit", ShellMenu.editItems()),
        ])
}
