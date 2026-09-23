# shell-kit

The macOS shell shared by the toolkit's web apps (SysML Modeler, Project
Planner, and the simpler single-window Profiler and Pyramid). An app keeps its
model, diagrams and every editing rule in its web code, served with no build
step; this package hosts that page in a `WKWebView` and adds what a browser tab
cannot: document windows, a real menu bar, Finder file opening, native save
panels and vector PDF export.

```
Package.swift                 SwiftPM library "ToolkitShell" (macOS 14, Swift 6 toolchain)
Sources/ToolkitShell/
  ShellConfig.swift           the per-app settings: names, scheme, file suffix, imports
  WebRoot.swift               <scheme>://app/… serving the web root; MIME table; path guard
  WebDocument.swift           NSDocument base: reads a file, hands its text to the page,
                              keeps the JSON the page reports, writes it back
  EditorWindowController.swift  the window, the WKWebView, the message channel
  PDFExporter.swift           SVG pages → one vector PDF, a page per diagram
  ShellMenu.swift             item / web / submenu / recentMenu and the standard menus
js/host.js                    the page's half of the bridge — apps vendor a copy
scripts/copy-into.mjs         copies js/host.js into an app; --check reports drift
Tests/                        swift test
```

## Adopting it

**1. Depend on the package** from the app's `macos/Package.swift`:

```swift
dependencies: [.package(name: "shell-kit", path: "../../shell-kit")],
targets: [.executableTarget(name: "MyApp", dependencies: [.product(name: "ToolkitShell", package: "shell-kit")],
                            swiftSettings: [.swiftLanguageMode(.v5)])]
```

**2. Write the app** — a config, a document subclass (usually empty), and the
menu table. That is the whole app target:

```swift
import AppKit
import ToolkitShell

final class ModelDocument: WebDocument {}   // add imports the page cannot read by overriding read()

@main enum MyApp {
    static func main() {
        let root = URL(fileURLWithPath: #filePath)   // …/macos/Sources/MyApp/App.swift → the repo
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        ShellApp.run(config: ShellConfig(appName: "My App", handlerName: "myapp", scheme: "myapp-app",
                                         fileSuffix: ".myapp.json", documentNoun: "model",
                                         importedTypes: ["public.xml"], repositoryRoot: root)) {
            ShellMenu.mainMenu(
                appMenuExtras: [ShellMenu.web("Appearance…", "view.appearance", ",")],
                menus: [
                    ShellMenu.submenu("File", ShellMenu.documentItems() + [.separator()] + ShellMenu.saveItems()
                        + [.separator(), ShellMenu.web("This Diagram as PDF…", "export.pdf", "e", [.command, .shift])]),
                    ShellMenu.submenu("Edit", ShellMenu.editItems()),
                ],
                helpItems: [ShellMenu.web("Working with My App", "help.guide", "?")])
        }
    }
}
```

`ShellMenu.web(title, id, key)` makes an item that runs a *web command id* in
the front window's page; `ShellMenu.item(title, selector, key)` is a plain
AppKit action. A test that every id the bar sends exists in the page's
`COMMANDS` table is three lines with `ShellMenu.webCommandIDs(in:)` and
`ShellMenu.commandIDs(inJavaScript:)`.

**3. Vendor the page's half** and wire it in:

```bash
node ../shell-kit/scripts/copy-into.mjs src/host.js
```

```js
import { hosted, post, initHost, saveViaHost } from './host.js';
// downloads → saveViaHost(blob, name) when hosted
// print → post({ type: 'pdf', name, pages: [{ svg, w, h }] }) when hosted
// menu bar / browser autosave → off when hosted
initHost({ name: 'myapp', load: loadText, command: runCommand, saved: markSaved });
// after every committed edit:
post({ type: 'changed', json: serialize(model), dirty, name: model.name });
```

The shell injects `window.__toolkitHost = 'myapp'` before the page's modules
load, so `hosted` is right at import time; `host.js` imports nothing, so a
model layer that imports it still loads under Node.

**4. Build the bundle** with your own script (see SysML's
`macos/scripts/build-app.sh`): copy the executable, `index.html`, `src/` and the
vendored kits into `Contents/Resources/web`, write `Info.plist`, sign ad hoc.
Run `node ../shell-kit/scripts/copy-into.mjs --check src/host.js` from that
script, next to ui-kit's and sync-kit's checks.

## The bridge

| Page → app | |
|---|---|
| `ready` | the page is up; the app hands it the file the document read |
| `changed` `{json, dirty, name}` | after every model edit. The document keeps the JSON, so saving never asks the page and waits |
| `saveFile` `{name, base64}` | an export: the app shows a save panel |
| `pdf` `{name, pages: [{svg, w, h}]}` | rendered offscreen by WebKit, joined with PDFKit: one vector page per diagram, each the diagram's size |
| `new` `open` `save` | the page's own shortcuts, forwarded to AppKit |
| `log` `{text}` | page errors, to the app's log |
| anything else | `EditorWindowController.handleMessage(type:body:)` — override it |

| App → page | |
|---|---|
| `window.<name>Host.load(text, name)` | a native file, or an import the page converts |
| `window.<name>Host.command(id)` | a menu command |
| `window.<name>Host.saved(name)` | the document was written |

Imports: a file `WebDocument.isImport(text:name:)` says yes to (by default,
anything XML) is handed to the page and the result becomes an **untitled,
unsaved document** — it is never written back over the file it came from.
Override `isImport` for CSV or the like; override `read` to convert formats
the page cannot read at all (Project Planner runs `.mpp` through MPXJ first,
then calls `deliver(text:name:imported: true)`).

## What stays app-specific

The web app itself. `Info.plist` and the document types it declares (the kit
never claims all JSON — register as an *Alternate* handler). The icon. The
menu table, and any extra message types. The bundle script. Fonts, if the app
needs the kit faces registered natively.
