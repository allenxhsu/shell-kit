#!/usr/bin/env node
// A stand-in for the toolkit Portal, for pairing a Mac app on this machine.
//
//   node scripts/dev-portal.mjs [--port 7788]
//
// It serves the two routes a native app touches, and nothing else:
//
//   GET    /devices/pair?scheme=<scheme>&label=<name>   the sign-in page
//   DELETE /auth/devices/<id>                           revoke, for Sign out
//   GET    /auth/devices                                what it has minted
//
// The real Portal (../Portal) puts Sign in with Google in front of that page
// and mints a token bound to an account; this mints a random one for anybody
// who clicks, so it belongs on a laptop and nowhere else. It listens on
// loopback only, for the same reason. What it is for is the half that is hard
// to test any other way: that the sheet opens, that the redirect comes back
// through Launch Services to a bundle that registered the scheme, and that the
// page then gets its `remote` message.
import { createServer } from 'node:http';
import { randomBytes } from 'node:crypto';

const args = process.argv.slice(2);
const port = Number(args[args.indexOf('--port') + 1]) || 7788;

/** @type {Map<string, {id: string, label: string, scheme: string, token: string, createdAt: string}>} */
const devices = new Map();

const escape = (text) => String(text).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// Only a bare lower-case scheme ever reaches the redirect, so a query
// parameter cannot turn this page into a redirector to anywhere else.
const SCHEME_RE = /^[a-z][a-z0-9.+-]*$/;

function pairPage(origin, scheme, label) {
  const id = randomBytes(6).toString('hex');
  const token = randomBytes(24).toString('base64url');
  devices.set(id, { id, label, scheme, token, createdAt: new Date().toISOString() });
  const link = `${scheme}://connect?url=${encodeURIComponent(origin)}&token=${encodeURIComponent(token)}&device=${id}`;
  console.log(`minted ${id} for ${label} (${scheme})`);
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Pair a device</title>
<style>
  :root { color-scheme: dark }
  body { margin:0; min-height:100vh; display:grid; place-items:center; background:#0a0f16; color:#dbe4f0;
         font:15px/1.6 ui-sans-serif,-apple-system,system-ui,sans-serif }
  main { width:min(420px,88vw); text-align:center }
  h1 { font-size:19px; margin:0 0 6px }
  p { color:#7d8ca3; margin:0 0 22px }
  a.button { display:inline-block; padding:11px 20px; border-radius:8px; background:#e8edf5; color:#0a0f16;
             text-decoration:none; font-weight:600 }
  small { display:block; margin-top:26px; color:#55637a }
</style></head><body><main>
  <h1>Pair this Mac</h1>
  <p>Pairing <b>${escape(label)}</b> with the development Portal at ${escape(origin)}.</p>
  <a class="button" href="${escape(link)}">Continue with Google</a>
  <small>Stand-in Portal — it signs nobody in and mints a token for whoever clicks.</small>
</main></body></html>`;
}

const server = createServer((request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);
  const send = (status, body, type = 'application/json') => {
    response.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' });
    response.end(typeof body === 'string' ? body : JSON.stringify(body));
  };

  if (request.method === 'GET' && url.pathname === '/devices/pair') {
    const scheme = url.searchParams.get('scheme') ?? '';
    if (!SCHEME_RE.test(scheme)) return send(400, { error: 'bad scheme' });
    const label = url.searchParams.get('label') || 'a Mac';
    return send(200, pairPage(url.origin, scheme, label), 'text/html; charset=utf-8');
  }

  if (request.method === 'GET' && url.pathname === '/auth/devices') {
    return send(200, [...devices.values()].map(({ token, ...rest }) => rest));
  }

  const revoking = request.method === 'DELETE' && url.pathname.match(/^\/auth\/devices\/([\w-]+)$/);
  if (revoking) {
    const found = devices.delete(revoking[1]);
    console.log(`${found ? 'revoked' : 'no such device:'} ${revoking[1]}`);
    return send(found ? 204 : 404, found ? '' : { error: 'no such device' });
  }

  send(404, { error: 'the real Portal serves the apps here; this one only pairs' });
});

server.listen(port, '127.0.0.1', () => {
  console.log(`stand-in Portal on http://127.0.0.1:${port} — pair at /devices/pair?scheme=<scheme>`);
});
