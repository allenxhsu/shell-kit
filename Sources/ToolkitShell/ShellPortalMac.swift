#if os(macOS)
import AppKit
import SyncKit

/// The Mac's way in to pairing: "Sign in to the toolkit…" and "Sign out" in
/// the app menu (`ShellMenu.portalItems()`), the Sync sheet where the
/// Portal's address lives, and alerts for what went wrong.
extension ShellPortal {
    // MARK: The menu items

    /// "Sign in to the toolkit…": the Sync sheet, where the Portal's address
    /// lives and the sign-in sheet starts.
    @objc public func showSyncSheet(_ sender: Any?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = origin
        field.placeholderString = "https://toolkit.example"
        field.lineBreakMode = .byTruncatingTail

        let alert = NSAlert()
        alert.messageText = "Sync \(config.appName) with the toolkit"
        alert.informativeText = isPaired
            ? "This Mac is paired with \(origin). Signing in again replaces the device token it holds."
            : "Sign in with Google in the sheet that opens. The Portal gives this Mac its own token, which you can revoke from its Devices page."
        alert.accessoryView = field
        alert.addButton(withTitle: isPaired ? "Pair Again…" : "Sign In…")
        alert.addButton(withTitle: "Cancel")

        let window = NSApp.keyWindow
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.origin = field.stringValue
            guard !self.origin.isEmpty else {
                self.report(title: "No Portal address", text: "Type the address of the toolkit Portal, such as https://toolkit.example.")
                return
            }
            Task { await self.pairShowingErrors() }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: respond) } else { respond(alert.runModal()) }
    }

    @objc public func signOutOfToolkit(_ sender: Any?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.signOut()
                if result.wasPaired, !result.revoked {
                    // The token is gone from this Mac either way. Saying so is
                    // the difference between "done" and "still revoke it".
                    self.report(title: "Signed out on this Mac",
                                text: "The Portal could not be reached, so its device token is still listed. Remove it from the Portal's Devices page when you are next online.")
                }
            } catch {
                self.report(title: "Could not sign out", text: error.localizedDescription)
            }
        }
    }

    func pairShowingErrors() async {
        do {
            _ = try await pair()
        } catch PairingError.cancelled {
            // The person closed the sheet. Nothing to report.
        } catch {
            report(title: "Could not sign in to the toolkit", text: error.localizedDescription)
        }
    }

    func report(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Sign out is only ever offered when there is something to sign out of.
    @objc public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(signOutOfToolkit(_:)) ? isPaired : true
    }
}
#endif
