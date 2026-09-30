// node --test js/   — the page's half of the bridge, under the three hosts it
// meets: the iPhone shell, the Mac shell (old and new), and a plain browser.
//
// host.js reads the globals the shell injects at import time, so each case
// sets them up and imports a fresh instance (a distinct query string is a
// distinct module to Node's loader).
import { test } from 'node:test';
import assert from 'node:assert/strict';

let instance = 0;

/** Pretend to be a shell (or not), then import host.js fresh. */
async function load({ name = null, platform, handlerName = name } = {}) {
  const posted = [];
  const g = globalThis;
  delete g.__toolkitHost;
  delete g.__toolkitPlatform;
  delete g.webkit;
  for (const key of Object.keys(g)) if (key.endsWith('Host')) delete g[key];
  if (name) g.__toolkitHost = name;
  if (platform !== undefined) g.__toolkitPlatform = platform;
  if (handlerName) g.webkit = { messageHandlers: { [handlerName]: { postMessage: (m) => posted.push(m) } } };
  g.document = { documentElement: { setAttribute() {} }, addEventListener() {} };
  const mod = await import(`./host.js?case=${instance++}`);
  return { mod, posted };
}

test('the iPhone shell: platform is ios and event reaches the page', async () => {
  const { mod, posted } = await load({ name: 'flow', platform: 'ios' });
  assert.equal(mod.hosted, true);
  assert.equal(mod.platform, 'ios');

  const events = [];
  assert.equal(mod.initHost({ name: 'flow', event: (e) => events.push(e) }), true);
  assert.deepEqual(posted, [{ type: 'ready' }]);

  const host = globalThis.flowHost;
  assert.deepEqual(Object.keys(host).sort(), ['command', 'event', 'load', 'remote', 'saved']);
  host.event({ type: 'open', url: 'flow://task/42' });
  assert.deepEqual(events, [{ type: 'open', url: 'flow://task/42' }]);
  // A page with no documents need not supply the document callbacks.
  assert.doesNotThrow(() => { host.load('{}', 'x.json'); host.command('file.new'); host.saved('x.json'); host.remote({ url: '', token: '' }); });
});

test('event is optional: the shell can always call it', async () => {
  const { mod } = await load({ name: 'sample', platform: 'macos' });
  assert.equal(mod.platform, 'macos');
  const loaded = [];
  mod.initHost({ name: 'sample', load: (t, n) => loaded.push([t, n]), command() {}, saved() {} });
  assert.equal(typeof globalThis.sampleHost.event, 'function');
  assert.doesNotThrow(() => globalThis.sampleHost.event({ type: 'anything' }));
  globalThis.sampleHost.load('text', 'a.json');
  assert.deepEqual(loaded, [['text', 'a.json']]);
});

test('a Mac shell from before platforms still reads as macos', async () => {
  const { mod } = await load({ name: 'sysml' });
  assert.equal(mod.hosted, true);
  assert.equal(mod.platform, 'macos');
});

test('a browser: not hosted, no platform, nothing posted', async () => {
  const { mod, posted } = await load();
  assert.equal(mod.hosted, false);
  assert.equal(mod.platform, null);
  assert.equal(mod.initHost({ name: 'flow', event() {} }), false);
  assert.equal(globalThis.flowHost, undefined);
  mod.post({ type: 'log', text: 'x' });
  assert.deepEqual(posted, []);
});

test('the page posts to the handler the shell named', async () => {
  const { mod, posted } = await load({ name: 'flow', platform: 'ios' });
  mod.post({ type: 'echo', text: 'hi' });
  mod.post({ type: 'portal.pair' });
  assert.deepEqual(posted, [{ type: 'echo', text: 'hi' }, { type: 'portal.pair' }]);
});
