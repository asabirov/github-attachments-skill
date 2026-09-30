// Upload with a GitHub token instead of a browser. A machine with a gh login
// uploads the bytes itself; one without runs gh-mint, which hands them to the
// broker on the machine that holds the token. Exit codes are in SKILL.md.

import { readFileSync, writeSync } from 'node:fs';
import { basename, extname } from 'node:path';
import { spawnSync } from 'node:child_process';

const [image, repo, timeout] = process.argv.slice(2);
const UPLOAD = 'https://uploads.github.com/user-attachments/assets';
const TYPES = {
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp',
};
const ASSET = /^https:\/\/github\.com\/user-attachments\/assets\/[0-9a-fA-F-]{36}$/;

// writeSync, not console: process.exit can drop a buffered write to a pipe.
const fail = (code, message) => { writeSync(2, `token: ${message}\n`); process.exit(code); };
const done = url => { writeSync(1, url + '\n'); process.exit(0); };
const oneline = text => (text || '').replace(/\s+/g, ' ').trim().slice(0, 200);

const budget = Number(timeout);
if (!Number.isInteger(budget) || budget < 1 || budget > 3600) fail(2, '--timeout wants 1 to 3600 whole seconds');
const deadline = Date.now() + budget * 1000;
// 1ms, not 0: spawnSync reads 0 as "no timeout" and AbortSignal.timeout throws on it.
const left = () => Math.max(1, deadline - Date.now());
// stdout here may be the token: it goes in a header, never in a message or a log.
const gh = args => spawnSync('gh', args, { encoding: 'utf8', timeout: left(), maxBuffer: 256 * 1024 });

// The name and the content type travel together in the upload's query, so the
// extension decides the type rather than the bytes.
const type = TYPES[extname(image).toLowerCase()];
if (!type) fail(9, `${basename(image)} is not a PNG, JPEG, GIF or WebP`);

// Asking gh is what picks the path. ORCA_GH_BROKER_PORT looks like the signal and
// is not: bin/setup renders it inside gh-mint, so no shell ever has it set.
const auth = gh(['auth', 'token']);
const token = auth.status === 0 ? auth.stdout.trim() : '';

if (!token) {
  const minted = spawnSync('gh-mint', [image, '--repo', repo], {
    encoding: 'utf8', timeout: left(), maxBuffer: 256 * 1024,
  });
  if (minted.error?.code === 'ENOENT') fail(9, 'no gh login here, and no gh-mint to reach the broker');
  if (minted.stderr) writeSync(2, minted.stderr);
  const url = (minted.stdout || '').trim();
  if (minted.status === 0 && ASSET.test(url)) done(url);
  // ETIMEDOUT and ENOBUFS are the only errors spawnSync invents for a child that
  // already ran, and 64, 75 and 77 are gh-mint's refusals before it sends anything.
  // Everything else may have uploaded, so it warns.
  const sent = ['ETIMEDOUT', 'ENOBUFS'].includes(minted.error?.code)
    || (!minted.error && ![64, 75, 77].includes(minted.status));
  if (minted.status === 64) fail(2, 'gh-mint refused the file; see its message above');
  fail(sent ? 7 : 8, minted.error
    ? `gh-mint failed: ${minted.error.code}`
    : `gh-mint exited ${minted.status} without an attachment URL`);
}

// The asset is bound to this id at upload time, so --repo must name the repository
// the link will be used in. gh's own stderr is never quoted: it can carry a token.
const id = gh(['api', `repos/${repo}`, '--jq', '.id']).stdout?.trim();
if (!/^[0-9]+$/.test(id || '')) fail(8, `cannot read the id of ${repo}; check the name and that this login can see it`);

let bytes;
try { bytes = readFileSync(image); }
catch (error) { fail(2, `cannot read ${image}: ${error.code || error.message}`); }

let answer;
try {
  const query = new URLSearchParams({ name: basename(image), content_type: type, repository_id: id });
  answer = await fetch(`${UPLOAD}?${query}`, {
    method: 'POST',
    body: bytes,
    headers: { Authorization: `token ${token}`, 'Content-Type': type, Accept: 'application/vnd.github+json' },
    // Never follow a redirect while the token is attached: it would be re-sent.
    redirect: 'manual',
    signal: AbortSignal.timeout(left()),
  });
} catch (error) {
  // A connection never made sent nothing; anything else may have reached GitHub.
  const unreached = ['ENOTFOUND', 'EAI_AGAIN', 'ECONNREFUSED'].includes(error.cause?.code);
  fail(unreached ? 8 : 7, `the upload did not complete: ${error.cause?.code || error.message}`);
}

const body = await answer.text().catch(() => '');
if (!answer.ok) fail(8, `GitHub refused the upload: HTTP ${answer.status} ${oneline(body)}`);
let parsed;
try { parsed = JSON.parse(body); } catch { parsed = {}; }
// The field holding it is undocumented, so the URL is matched on its shape.
const url = Object.values(parsed || {}).find(v => typeof v === 'string' && ASSET.test(v));
if (!url) fail(7, `the upload answered HTTP ${answer.status} without an attachment URL`);
done(url);
