// shell-kit/js/host.js — the page's half of the bridge to the native shell
// (ToolkitShell, ../shell-kit): the Mac app's document windows, or the iPhone
// app's one full-screen web view. Apps vendor a copy of this file:
//   node ../shell-kit/scripts/copy-into.mjs src/host.js
//
// In a browser `hosted` is false and nothing here does anything. Hosted, the
// native side owns what a browser cannot do well — documents, the menu bar,
// save panels, PDF — and this module is the only place the two sides meet:
//
//   page → app   post({ type, … })            ready | changed | saveFile | pdf | new | open | save | log
//                                               | portal.pair | portal.signOut | <any type the app handles>
//   app → page   window.<name>Host.load(text, name)   put a file's text into this window
//                window.<name>Host.command(id)        run a menu command
//                window.<name>Host.saved(name)        the document was written
//                window.<name>Host.remote({url, token})  the toolkit Portal this device paired with
//                window.<name>Host.event(event)       anything else the app sends: a deep link
//                                                     ({ type: 'open', url }), a custom handler's reply
//
// `event` and `platform` are the newest (added with the iPhone shell). `event`
// is the app's general channel back to the page, as `post` is the page's to
// the app: a type the shell does not know goes to the app's own handlers, and
// whatever they send back arrives here. `platform` says which shell this is —
// 'ios', 'macos', or null in a browser — so a page can hide what a phone
// cannot do (a PDF export, say) without sniffing the user agent.
//
// `remote` came with Portal pairing: the shell signs
// in through a sign-in sheet, keeps the device token in the Keychain, and
// hands the page the same two values its own Sync settings hold — so the page
// treats them exactly as if they had been typed in, and does not care that a
// Keychain was involved. It arrives when the page reports ready and again
// whenever the person signs in or out; two empty strings mean signed out, the
// same as clearing those fields by hand. A vendored copy without `remote` or
// `event` is a stale copy: `copy-into.mjs --check` will say so.
//
// The shell injects `window.__toolkitHost = '<name>'` and
// `window.__toolkitPlatform = 'ios' | 'macos'` before any module loads, so
// `hosted` and `platform` are known at import time; `initHost({ name })` names
// the same handler. Imports nothing, so a model layer that depends on it still
// loads under Node.

const injectedName = typeof globalThis.__toolkitHost === 'string' ? globalThis.__toolkitHost : null;
let handler = injectedName ? globalThis.webkit?.messageHandlers?.[injectedName] : null;

/** True inside a native shell, Mac or iPhone. */
export const hosted = !!handler;

/**
 * Which shell: 'ios', 'macos', or null in a browser. A Mac shell from before
 * the iPhone one injects no platform, and is the only shell that could.
 * @type {'ios' | 'macos' | null}
 */
export const platform = hosted
  ? (typeof globalThis.__toolkitPlatform === 'string' ? globalThis.__toolkitPlatform : 'macos')
  : null;

export function post(message) {
  if (handler) handler.postMessage(message);
}

function toBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1] || '');
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

/** Hand a file to the app, which asks where to save it. */
export async function saveViaHost(blob, filename) {
  post({ type: 'saveFile', name: filename, base64: await toBase64(blob) });
}

const noop = () => {};

/**
 * Expose the page's callbacks to the shell and tell it the page is ready.
 *
 * Every callback but `name` is optional and defaults to a no-op, so the shell
 * can always make a call without asking what the page supports: an app with
 * no sync has no `remote`, an app with no documents (the iPhone shell has
 * none) no `load`, `command` or `saved`, and an app nobody sends events to no
 * `event`.
 * @param {{name: string, load?: (text: string, fileName: string) => any, command?: (id: string) => void, saved?: (fileName: string) => void, remote?: (settings: {url: string, token: string}) => void, event?: (event: {type: string, [key: string]: any}) => void}} api
 */
export function initHost({ name, load = noop, command = noop, saved = noop, remote = noop, event = noop }) {
  handler = handler || globalThis.webkit?.messageHandlers?.[name] || null;
  if (!handler) return false;
  globalThis[`${name}Host`] = { load, command, saved, remote, event };
  document.documentElement.setAttribute('data-hosted', '');
  // The web view's own context menu offers Reload, which would discard the window's document.
  document.addEventListener('contextmenu', (e) => {
    if (!/^(INPUT|TEXTAREA)$/.test(e.target.tagName)) e.preventDefault();
  });
  post({ type: 'ready' });
  return true;
}
