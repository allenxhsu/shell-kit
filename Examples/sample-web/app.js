// The page half of the sample: what any toolkit app does with the shell, cut
// down to a text box. The part worth reading is `remote`.
import { hosted, post, initHost } from './host.js';

const el = (id) => document.getElementById(id);
const note = el('note');

let fileName = 'Untitled note';
let remotes = 0;

/**
 * What a real app's sync module does with the pair: nothing special.
 *
 * These are the same two values its Sync settings hold, so the app stores them
 * where it stores what someone typed and points its sync engine at them. That
 * the shell got them from the Keychain instead of a text field is not
 * something the page has to know — which is the whole point of the message.
 *
 *   settings.url = url; settings.token = token;
 *   engine.setRemote(url ? new HttpTransport({ baseUrl: `${url}/w/sample`, token }) : null);
 *
 * Empty strings mean signed out, the same as clearing the fields by hand.
 */
function remote({ url, token }) {
  remotes += 1;
  el('remote-count').textContent = remotes === 1 ? 'once' : `${remotes} times`;
  el('remote-url').textContent = url || '— (signed out)';
  el('remote-url').className = url ? 'yes' : 'no';
  // Enough to prove the token arrived intact; a token is not something to
  // leave sitting on a screen.
  el('remote-token').textContent = token ? `${token.length} characters, ending ${token.slice(-4)}` : '—';
  el('remote-token').className = token ? 'yes' : 'no';
  // Into the app's log as well, so `scripts/build-sample-app.sh` can be
  // checked from a terminal without anyone watching the window.
  post({ type: 'log', text: `remote #${remotes}: url=${url || '(none)'} token=${token.length} chars` });
}

function serialize() {
  return JSON.stringify({ format: 'shell-kit.sample/1', name: fileName, text: note.value }, null, 2);
}

function load(text, name) {
  try {
    const parsed = JSON.parse(text);
    note.value = parsed.text ?? '';
    fileName = parsed.name ?? name ?? fileName;
  } catch {
    note.value = text;
  }
  el('doc-name').textContent = name || fileName;
  changed(false);
}

function changed(dirty = true) {
  post({ type: 'changed', json: serialize(), dirty, name: fileName });
}

note.addEventListener('input', () => changed());

el('hosted').textContent = hosted ? 'yes' : 'no — open it in the built app';
el('hosted').className = hosted ? 'yes' : 'no';
el('doc-name').textContent = fileName;

initHost({
  name: 'sample',
  load,
  command: (id) => post({ type: 'log', text: `unhandled command ${id}` }),
  saved: (name) => { fileName = name; el('doc-name').textContent = name; },
  remote,
});
