// Upload with a GitHub token. A machine with a gh login uploads the bytes
// itself; one without runs gh-mint, which hands them to the broker on the
// machine that holds the token. Exit codes are in SKILL.md.

import { readFileSync, writeSync } from 'node:fs';
import { basename, extname } from 'node:path';
import { spawnSync } from 'node:child_process';

const [image, repo, timeout] = process.argv.slice(2);
const UPLOAD = 'https://uploads.github.com/user-attachments/assets';
const TYPES = {
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp',
};
// Byte offsets each type must match, checked against what is about to be uploaded:
// a symlink named x.png pointing at a private key passes every check made on the
// path, and this is what stops those bytes reaching GitHub. WebP needs the WEBP at
// offset 8 as well, or any RIFF container would pass.
const MAGIC = {
  'image/png': [[0, 0x89], [1, 0x50], [2, 0x4e], [3, 0x47]],
  'image/jpeg': [[0, 0xff], [1, 0xd8], [2, 0xff]],
  'image/gif': [[0, 0x47], [1, 0x49], [2, 0x46], [3, 0x38]],
  'image/webp': [[0, 0x52], [1, 0x49], [2, 0x46], [3, 0x46],
                 [8, 0x57], [9, 0x45], [10, 0x42], [11, 0x50]],
};
const ASSET = /^https:\/\/github\.com\/user-attachments\/assets\/[0-9a-fA-F-]{36}$/;

// writeSync, not console: process.exit can drop a buffered write to a pipe.
const fail = (code, message) => { writeSync(2, `token: ${message}\n`); process.exit(code); };
const done = url => { writeSync(1, url + '\n'); process.exit(0); };
const oneline = text => (text || '').replace(/\s+/g, ' ').trim().slice(0, 200);

// mint.sh refuses a --timeout it cannot use; this only keeps Node's own limits.
const budget = Math.min(Math.max(Math.trunc(Number(timeout)) || 60, 1), 3600);
const deadline = Date.now() + budget * 1000;
// 1ms, not 0: spawnSync reads 0 as "no timeout" and AbortSignal.timeout throws on it.
const left = () => Math.max(1, deadline - Date.now());
// stdout here may be the token: it goes in a header, never in a message or a log.
const gh = args => spawnSync('gh', args, { encoding: 'utf8', timeout: left(), maxBuffer: 256 * 1024 });

// The name and the content type travel together in the upload's query, so the
// extension decides the type rather than the bytes.
const type = TYPES[extname(image).toLowerCase()];
if (!type) fail(9, `${basename(image)} is not a PNG, JPEG, GIF or WebP`);

// Judge the bytes, not the path mint.sh looked at: a symlink named x.png can point
// at anything. Before the path choice, so neither route can carry them away.
let bytes;
try { bytes = readFileSync(image); }
catch (error) { fail(2, `cannot read ${image}: ${error.code || error.message}`); }
if (bytes.length > 10 * 1024 * 1024) fail(2, `${basename(image)} is over GitHub's 10 MB limit`);
if (!MAGIC[type].every(([at, byte]) => bytes[at] === byte)) {
  fail(2, `${basename(image)} is named ${extname(image)} but its bytes are not ${type}`);
}

// Asking gh is what picks the path. ORCA_GH_BROKER_PORT looks like the signal and
// is not: bin/setup renders it inside gh-mint, so no shell ever has it set.
const auth = gh(['auth', 'token', '--hostname', 'github.com']);
const token = auth.status === 0 ? auth.stdout.trim() : '';

if (!token) {
  // The broker reads the body under a 30s deadline and then caps the mint at 90s,
  // so gh-mint waits up to 150s. Killing it at --timeout would report 7 for an
  // upload still in flight, and the retry that follows would duplicate the asset.
  const minted = spawnSync('gh-mint', [image, '--repo', repo], {
    encoding: 'utf8', timeout: Math.max(left(), 150_000), maxBuffer: 256 * 1024,
  });
  if (minted.error?.code === 'ENOENT') fail(9, 'no gh login or gh-mint; run `gh auth login` or set up the broker\'s `gh-mint`');
  if (minted.stderr) writeSync(2, minted.stderr);
  const url = (minted.stdout || '').trim();
  if (minted.status === 0 && ASSET.test(url)) done(url);
  // The broker's exit says whether anything reached GitHub. 64 and 77 are refusals
  // before sending, and 75 means nothing was stored: nothing sent, or GitHub answered
  // 4xx. 76 means the bytes may be on GitHub (its 90s cap, a dropped connection, a
  // 5xx, a 2xx with no URL), and so does any code this does not know.
  const sent = ['ETIMEDOUT', 'ENOBUFS'].includes(minted.error?.code)
    || (!minted.error && ![64, 75, 77].includes(minted.status));
  if (minted.status === 64) fail(2, 'gh-mint refused the file; see its message above');
  const meaning = { 75: '; nothing was stored, so a retry is safe',
    76: '; the image may already be on GitHub, so check before minting it again' };
  fail(sent ? 7 : 8, minted.error
    ? `gh-mint failed: ${minted.error.code}`
    : `gh-mint exited ${minted.status} without an attachment URL${meaning[minted.status] || ''}`);
}

// The asset is bound to this id at upload time, so --repo must name the repository
// the link will be used in. gh's own stderr is never quoted: it can carry a token.
const id = gh(['api', `repos/${repo}`, '--jq', '.id']).stdout?.trim();
if (!/^[0-9]+$/.test(id || '')) fail(8, `cannot read the id of ${repo}; check the name and that this login can see it`);

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
// A 5xx can arrive after the asset was stored, so it warns; a 4xx is a refusal.
if (!answer.ok) fail(answer.status >= 500 ? 7 : 8, `GitHub answered HTTP ${answer.status} ${oneline(body)}`);
let parsed;
try { parsed = JSON.parse(body); } catch { parsed = {}; }
// The field holding it is undocumented, so the URL is matched on its shape.
const url = Object.values(parsed || {}).find(v => typeof v === 'string' && ASSET.test(v));
if (!url) fail(7, `the upload answered HTTP ${answer.status} without an attachment URL`);
done(url);
