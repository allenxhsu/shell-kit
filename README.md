# shell-kit

The native shell shared by the toolkit's web apps — on the Mac SysML Modeler,
Project Planner, and the simpler single-window Profiler and Pyramid; on the
iPhone, Flow. An app keeps its model, diagrams and every editing rule in its
web code, served with no build step; this package hosts that page in a
`WKWebView` and adds what a browser tab cannot. On the Mac: document windows, a
real menu bar, Finder file opening, native save panels and vector PDF export.
On the iPhone: a full-screen app with its page bundled offline, deep links and
the share sheet. On both: signing in to the toolkit's online Portal, and a
two-way message channel for whatever else the app adds natively.

```
Package.swift                 SwiftPM library "ToolkitShell" (macOS 14, iOS 17, Swift 6 toolchain)
Sources/ToolkitShell/
  ShellConfig.swift           the per-app settings: names, scheme, file suffix, imports,
                              deep-link scheme, app message handlers, web root
  ShellBridge.swift           both platforms: ShellPage, message routing, events to the page,
                              the scripts injected before the page loads
  WebRoot.swift               <scheme>://app/… serving the web root; MIME table; path guard
  ShellScene.swift            iOS: the SwiftUI Scene — one full-screen web view
  WebDocument.swift           NSDocument base: reads a file, hands its text to the page,
                              keeps the JSON the page reports, writes it back
  EditorWindowController.swift  the window, the WKWebView, the message channel
  PDFExporter.swift           SVG pages → one vector PDF, a page per diagram
  ShellMenu.swift             item / web / submenu / recentMenu and the standard menus
  ShellPortal.swift           pairing with the Portal: the Keychain, and `remote` into
                              every open page (both platforms)
  ShellPortalMac.swift        macOS: the menu items and the Sync sheet
  ShellPlist.swift            reads a built bundle back: is the connect scheme registered?
js/host.js                    the page's half of the bridge — apps vendor a copy
js/host.test.mjs              node --test js/host.test.mjs
scripts/copy-into.mjs         copies js/host.js into an app; --check reports drift
scripts/url-types.mjs         the CFBundleURLTypes block for a build script's Info.plist
scripts/dev-portal.mjs        a stand-in Portal, for pairing an app on this machine
scripts/build-sample-app.sh   builds Examples/ into an app bundle
Examples/sample-web/          the smallest page the shell can host, with pairing
Sources/PairingSample/        and the ten lines of Swift around it on the Mac,
Examples/ios-sample/          and on the iPhone (an XcodeGen project.yml)
Tests/                        swift test
.github/workflows/ci.yml      swift build + swift test, the iOS sample for the Simulator
```

Everything in `Sources/ToolkitShell` that touches AppKit is fenced with
`#if os(macOS)`, and `ShellScene` with `#if os(iOS)`; the config, `WebRoot`,
the message routing and the Portal's core are one copy for both.

It depends on [`../sync-kit/swift`](../sync-kit/swift) for `PairingFlow`, so a
clone needs `sync-kit` beside it — the same assumption the apps already make
when they vendor sync-kit's JavaScript. sync-kit is private; the public
[flow](https://github.com/allenxhsu/flow) repository vendors it, `swift/`
folder included, so a checkout without access to sync-kit can stand flow's
copy in its place — which is what CI does:

```bash
git clone https://github.com/allenxhsu/flow
ln -s flow/sync-kit sync-kit          # beside shell-kit/
cd shell-kit && swift build && swift test
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

The shell injects `window.__toolkitHost = 'myapp'` (and
`window.__toolkitPlatform`) before the page's modules load, so `hosted` and
`platform` are right at import time; `host.js` imports nothing, so a model
layer that imports it still loads under Node. Every `initHost` callback but
`name` is optional.

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
| `portal.pair` `{origin?}` / `portal.signOut` | what the Portal menu items do, asked for by the page (the iPhone has no menu) |
| anything else | `EditorWindowController.handleMessage(type:body:)` if overridden, then `ShellConfig.handlers[type]` |

| App → page | |
|---|---|
| `window.<name>Host.load(text, name)` | a native file, or an import the page converts |
| `window.<name>Host.command(id)` | a menu command |
| `window.<name>Host.saved(name)` | the document was written |
| `window.<name>Host.remote({url, token})` | the Portal this Mac is paired with, or two empty strings for signed out. The page's sync module treats them exactly as values typed into its own Sync settings |
| `window.<name>Host.event(event)` | everything else: a handler's `page.send(…)`, a deep link as `{type: 'open', url}`. Held until the page has reported `ready` |

The shell also sets `window.__toolkitPlatform` (`'macos'` or `'ios'`) before
the page loads; `host.js` exports it as `platform`, `null` in a browser.

**App handlers.** A message type the shell does not know goes to the app's
`handlers`, and the handler answers through the page — the same on both
platforms:

```swift
ShellConfig(appName: "My App", handlerName: "myapp", …,
            handlers: ["echo": { message, page in
                page.send(["type": "echo", "text": message["text"] as? String ?? ""])
            }])
```
```js
initHost({ name: 'myapp', event: (e) => { if (e.type === 'echo') show(e.text); } });
post({ type: 'echo', text: 'hello' });
```

A handler is `@MainActor`; `page` is a `ShellPage` (`send(_:)` takes JSON
values only). The shell's own types (`ShellMessage.builtInTypes`) never reach a
handler, even one registered under the same name.

## On the iPhone

`ShellScene` is the whole app:

```swift
import SwiftUI
import ToolkitShell

@main struct MyApp: App {
    var body: some Scene {
        ShellScene(config: ShellConfig(
            appName: "My App", handlerName: "myapp",
            portalOrigin: "https://toolkit.example",          // optional: pairing
            urlScheme: "myapp",                                // optional: deep links
            handlers: ["echo": { message, page in page.send(["type": "echo"]) }],
            webRoot: Bundle.main.url(forResource: "web", withExtension: nil)!))
    }
}
```

- **The page** is the app's web folder, bundled as a folder reference and
  served from `<scheme>://app/…` (`scheme` defaults to `<handlerName>-app`)
  through the same handler, path guard and MIME table as the Mac, so ES
  modules and `localStorage` behave the same. No document fields are needed;
  `fileSuffix`, `documentNoun` and the rest have defaults.
- **The view** runs edge to edge in the page's background colour, with the web
  view itself inside the safe area; no bounce, no pinch or double-tap zoom,
  and Safari's Web Inspector attaches in debug builds. `alert`, `confirm` and
  `prompt` show native alerts; links out open in Safari.
- **Deep links:** `myapp://…` from anywhere (a widget, a Live Activity, a
  notification) reaches the page as `event({ type: 'open', url })`, held until
  the page is ready, so a cold launch loses nothing. Declare the scheme in the
  app's `Info.plist` `CFBundleURLTypes`.
- **Files:** `saveViaHost(blob, name)` opens the share sheet (Save to Files,
  AirDrop, Mail). `<input type="file">` needs nothing: WebKit's own picker
  offers Files and Photos.
- **The Portal:** there is no menu, so the page asks — `post({ type:
  'portal.pair' })` opens the same `ASWebAuthenticationSession` sign-in as the
  Mac and `remote({url, token})` follows; `post({ type: 'portal.signOut' })`
  revokes and forgets. `remote` is also sent on every `ready`. The connect
  scheme follows `handlerName` as on the Mac and may be the same as
  `urlScheme`: a `<scheme>://connect?…` link goes to pairing first.
- **Documents, menus, PDF:** none. `changed`, `pdf`, `new`, `open` and `save`
  are accepted and ignored, so one page can serve both shells; check
  `platform` to hide what a phone cannot do.

`Examples/ios-sample` is the sample page in `ShellScene` with an `echo`
handler; `xcodegen generate` there makes the project (see its `project.yml`).

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
