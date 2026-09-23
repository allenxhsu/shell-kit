#!/usr/bin/env node
// Vendor js/host.js into an app, or check that an app's copy is current.
//
//   node ../shell-kit/scripts/copy-into.mjs src/host.js            # copy
//   node ../shell-kit/scripts/copy-into.mjs --check src/host.js    # exit 1 and say so if it drifted
//
// The copy carries a header naming this repository's commit and the date, the
// same convention as ../ui-kit's copy-into.mjs; --check compares the body
// below that header, so a refreshed header alone never counts as drift.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';

const kit = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(resolve(kit, 'js/host.js'), 'utf8');
const args = process.argv.slice(2);
const check = args.includes('--check');
const targets = args.filter((a) => a !== '--check');
if (!targets.length) { console.error('usage: copy-into.mjs [--check] <target-file>...'); process.exit(2); }

let commit = 'unknown';
try { commit = execSync('git rev-parse --short HEAD', { cwd: kit, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim(); } catch {}
const header = `// VENDORED COPY of ../shell-kit/js/host.js (commit ${commit}, ${new Date().toISOString().slice(0, 10)}).\n// Do not edit here: change shell-kit, then run  node ../shell-kit/scripts/copy-into.mjs <this file>\n\n`;
const body = (text) => text.replace(/^\/\/ VENDORED COPY[^\n]*\n\/\/ Do not edit[^\n]*\n\n/, '');

let drift = 0;
for (const t of targets) {
  const target = resolve(t);
  const current = existsSync(target) ? readFileSync(target, 'utf8') : null;
  if (check) {
    if (current === null) { console.log(`missing: ${t}`); drift++; }
    else if (body(current) !== source) { console.log(`drifted: ${t}`); drift++; }
  } else {
    writeFileSync(target, header + source);
    console.log(`copied → ${t}`);
  }
}
if (check) { console.log(drift ? `${drift} file(s) out of date` : 'shell-kit copies are current'); process.exit(drift ? 1 : 0); }
