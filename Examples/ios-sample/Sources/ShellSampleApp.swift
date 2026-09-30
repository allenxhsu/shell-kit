// Shell Sample for iPhone — Examples/sample-web in the iPhone shell. The
// whole app is this: a config and one handler.
//
// `echo` is the app-specific message both samples answer: the page posts
// `{ type: 'echo', text }` and the handler sends `{ type: 'echo', text,
// platform }` back through `window.sampleHost.event(…)`. A deep link,
// `shellsample://anything`, shows up the same way as `{ type: 'open', url }`.
import SwiftUI
import ToolkitShell

@main
struct ShellSampleApp: App {
    var body: some Scene {
        ShellScene(config: ShellConfig(
            appName: "Shell Sample",
            handlerName: "sample",
            // The stand-in Portal (scripts/dev-portal.mjs) on the Mac running the Simulator.
            portalOrigin: "http://127.0.0.1:7788",
            connectScheme: "shellsample",
            urlScheme: "shellsample",
            handlers: [
                "echo": { message, page in
                    page.send(["type": "echo", "text": message["text"] as? String ?? "", "platform": "ios"])
                },
            ],
            webRoot: Bundle.main.url(forResource: "sample-web", withExtension: nil)!))
    }
}
