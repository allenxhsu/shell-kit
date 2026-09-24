# shell-kit

The macOS shell shared by the toolkit's web apps (SysML Modeler, Project
Planner, and the simpler single-window Profiler and Pyramid). An app keeps its
model, diagrams and every editing rule in its web code, served with no build
step; this package hosts that page in a `WKWebView` and adds what a browser tab
cannot: document windows, a real menu bar, Finder file opening, native save
panels, vector PDF export, and signing in to the toolkit's online Portal.

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
  ShellPortal.swift           pairing with the Portal: the menu items, the Sync sheet,
                              the Keychain, and `remote` into every open page
  ShellPlist.swift            reads a built bundle back: is the connect scheme registered?
js/host.js                    the page's half of the bridge — apps vendor a copy
scripts/copy-into.mjs         copies js/host.js into an app; --check reports drift
scripts/url-types.mjs         the CFBundleURLTypes block for a build script's Info.plist
scripts/dev-portal.mjs        a stand-in Portal, for pairing an app on this machine
scripts/build-sample-app.sh   builds Examples/ into an app bundle
Examples/sample-web/          the smallest page the shell can host, with pairing
Sources/PairingSample/        and the ten lines of Swift around it
Tests/                        swift test
```

It depends on [`../sync-kit/swift`](../sync-kit/swift) for `PairingFlow`, so a
clone needs `sync-kit` beside it — the same assumption the apps already make
when they vendor sync-kit's JavaScript.

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
                                         importedTypes: ["public.xml"], repositoryRoot: root,
                                         portalOrigin: "https://toolkit.example")) {   // opt in to pairing
            ShellMenu.mainMenu(
                appMenuExtras: [ShellMenu.web("Appearance…", "view.appearance", ",")] + ShellMenu.portalItems(),
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
`macos/scripts/build-app.sh`, or `scripts/build-sample-app.sh` here): copy the
executable, `index.html`, `src/` and the vendored kits into
`Contents/Resources/web`, write `Info.plist`, sign ad hoc. Run
`node ../shell-kit/scripts/copy-into.mjs --check src/host.js` from that script,
next to ui-kit's and sync-kit's checks. An app that pairs also writes the URL
type into that `Info.plist` — see below.

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
| `window.<name>Host.remote({url, token})` | the Portal this Mac is paired with, or two empty strings for signed out. The page's sync module treats them exactly as values typed into its own Sync settings |

## Signing in to the Portal

The toolkit's apps are served online by the [Portal](../Portal) behind Sign in
with Google. A browser tab signs in and keeps a cookie; a Mac app cannot use
that cookie, and Google refuses to sign anyone in inside an app's own web view.
So the app **pairs**, through sync-kit's `PairingFlow`:

```
Sign in to the toolkit…  →  <origin>/devices/pair?scheme=<connect scheme>   in a sign-in sheet
                            (Safari's sandbox, Safari's cookies, Google's real page)
                        ←   <scheme>://connect?url=<origin>&token=<token>   Launch Services
   Keychain ← url, token                                                    the app delegate
   window.<name>Host.remote({url, token})  →  the page, which syncs
```

**Opting in** is one argument. `portalOrigin:` is the app's default address —
the person can point it elsewhere in the Sync sheet, and what they typed wins
from then on. `connectScheme:` follows `handlerName` unless you say otherwise,
and is the `connectScheme` field of the app's `toolkit-app.json`. An app that
sets neither has no menu items, no URL type and no behaviour it did not have
before: `ShellMenu.portalItems()` returns nothing, and the delegate does not
even claim `application(_:open:)`, so AppKit's own document opening is
untouched.

**The URL type is not optional.** Launch Services delivers `<scheme>://connect`
only to a bundle that claims the scheme, and nothing in the app can make up for
its absence: the sheet opens, the person signs in, and the callback vanishes.
Two lines in the build script:

```sh
URL_TYPES="$(node ../shell-kit/scripts/url-types.mjs myapp 'My App')"   # before the heredoc
…
$URL_TYPES                                                              # inside the top-level <dict>
…
node ../shell-kit/scripts/url-types.mjs --check "$APP/Contents/Info.plist" myapp   # after it
```

`ShellPlist.declares(scheme:inPlist:)` is the same question from Swift, for an
app's own test over its built bundle.

**The page** gets `remote({url, token})` when it reports ready and again on
every sign-in and sign-out, and does with the pair what it does with a URL and
token typed into its own Sync settings — the point of the message is that the
page never learns a Keychain was involved:

```js
initHost({ name: 'myapp', load, command, saved, remote: ({ url, token }) => {
  settings.url = url; settings.token = token;              // exactly as if typed
  engine.setRemote(url ? new HttpTransport({ baseUrl: `${url}/w/myapp`, token }) : null);
} });
```

Two empty strings mean signed out, which is what clearing those fields by hand
does. `remote` is optional in `initHost`; an app with no sync gets a no-op.

**Sign out** revokes the device at the Portal (`DELETE /auth/devices/<id>`,
authenticated with the token it is giving up) and then forgets the Keychain
items. It forgets them even when the Portal cannot be reached — someone signing
out on a plane means it — and says so, because a token still listed is one the
person should remove from the Devices page later. A connect link that carries
no `device` id (a QR code pairing two machines on a LAN, which has no Portal
behind it) can only be forgotten locally.

**Trying it** without a Portal, or without an app:

```bash
node scripts/dev-portal.mjs          # a stand-in Portal on 127.0.0.1:7788
scripts/build-sample-app.sh          # → build/Pairing Sample.app
open "build/Pairing Sample.app"      # Sign in to the toolkit… → Sign In…
```

The sample's window shows each `remote` it receives. The stand-in Portal signs
nobody in and mints a token for whoever clicks, so it belongs on a laptop and
nowhere else.

Imports: a file `WebDocument.isImport(text:name:)` says yes to (by default,
anything XML) is handed to the page and the result becomes an **untitled,
unsaved document** — it is never written back over the file it came from.
Override `isImport` for CSV or the like; override `read` to convert formats
the page cannot read at all (Project Planner runs `.mpp` through MPXJ first,
then calls `deliver(text:name:imported: true)`).

## What stays app-specific

The web app itself. `Info.plist` and the document types it declares (the kit
never claims all JSON — register as an *Alternate* handler; the connect URL
type comes from `url-types.mjs`). The icon. The menu table, and any extra
message types. The bundle script. Fonts, if the app needs the kit faces
registered natively. What the page does with `remote` — the shell hands over a
URL and a token and has no opinion about syncing.
