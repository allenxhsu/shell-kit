#!/usr/bin/env node
// Write the CFBundleURLTypes block that lets a paired app receive its connect
// link, for the Info.plist an app's build script generates.
//
//   node ../shell-kit/scripts/url-types.mjs sysml "SysML Modeler"     # print the block
//   node ../shell-kit/scripts/url-types.mjs --check <Info.plist> sysml  # exit 1 if it is missing
//
// The build script interpolates it into its heredoc:
//
//   URL_TYPES="$(node ../shell-kit/scripts/url-types.mjs sysml 'SysML Modeler')"
//   cat > "$APP/Contents/Info.plist" <<PLIST
//   …
//   $URL_TYPES
//   </dict>
//   </plist>
//   PLIST
//
// Pairing ends with the Portal redirecting to sysml://connect?url=…&token=…
// and Launch Services will only deliver that to an app whose bundle claims the
// scheme. Nothing else in the app can make up for it being absent: the sheet
// opens, the person signs in, and the callback goes nowhere. --check reads a
// built bundle back and says so before anyone finds out by hand.
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const check = args.includes('--check');
const rest = args.filter((a) => a !== '--check');

const usage = 'usage: url-types.mjs <scheme> [display name]\n       url-types.mjs --check <Info.plist> <scheme>';
if (check ? rest.length < 2 : rest.length < 1) { console.error(usage); process.exit(2); }

// Launch Services compares schemes case-insensitively and a scheme with
// anything exotic in it will not survive a redirect; the apps all use one
// lower-case word, so hold everyone to that rather than emitting a plist that
// silently never matches.
const validate = (scheme) => {
  if (!/^[a-z][a-z0-9.+-]*$/.test(scheme)) {
    console.error(`bad scheme "${scheme}": lower-case, starting with a letter, as in "sysml"`);
    process.exit(2);
  }
  return scheme;
};

const escape = (text) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** The block itself, indented to sit inside the plist's top-level <dict>. */
export function urlTypesBlock(scheme, name) {
  return `  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <!-- Pairing with the Portal ends in ${escape(scheme)}://connect?url=…&amp;token=…,
           which Launch Services only delivers to an app that claims the scheme.
           Written by ../shell-kit/scripts/url-types.mjs — do not hand-edit. -->
      <key>CFBundleURLName</key><string>${escape(name)} Connect</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>${escape(scheme)}</string></array>
    </dict>
  </array>`;
}

if (check) {
  const [plistPath, rawScheme] = rest;
  const scheme = validate(rawScheme);
  let plist;
  try {
    plist = readFileSync(plistPath, 'utf8');
  } catch {
    console.error(`cannot read ${plistPath}`);
    process.exit(1);
  }
  // A string comparison, not a plist parse: this runs from a shell script on a
  // machine that has node and nothing else, and the question is only whether
  // the scheme is in there.
  const schemes = [...plist.matchAll(/<key>CFBundleURLSchemes<\/key>\s*<array>([\s\S]*?)<\/array>/g)]
    .flatMap((m) => [...m[1].matchAll(/<string>([^<]*)<\/string>/g)].map((s) => s[1].toLowerCase()));
  if (schemes.includes(scheme.toLowerCase())) {
    console.log(`${plistPath} registers ${scheme}://`);
    process.exit(0);
  }
  console.error(`${plistPath} does not register ${scheme}:// — pairing callbacks will never arrive`);
  process.exit(1);
}

const [rawScheme, name] = rest;
console.log(urlTypesBlock(validate(rawScheme), name ?? rawScheme));
