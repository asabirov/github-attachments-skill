// Upload the image with a GitHub token instead of a browser session.
//
// GitHub shipped a token-authenticated attachment upload on 2026-09-01, which is
// the reason this driver can exist at all: the 422 recorded in lib/paste.js was
// measured on 2026-09-03 against a different, older endpoint, and this one answers
// 201 for an image to `Authorization: token` and to `Bearer` alike (issue #3).
//
// Two paths, decided by where the token lives. On the machine that holds the gh
// login, this process uploads the bytes itself. A remote host holds no GitHub
// credential at all, so `gh-mint` hands the bytes to the broker on that machine,
// which uploads them there and sends back only the URL.
//
// Exit 9 means neither path is open here, and is the signal mint.sh reads before
// it starts a browser instead. Every other non-zero exit is a real failure of the
// path that was chosen, and must not silently become a browser upload.

import { readFileSync, writeSync } from 'node:fs';
import { basename, extname } from 'node:path';
import { spawnSync } from 'node:child_process';

const [image, repo, timeout] = process.argv.slice(2);
const timeoutMs = Number(timeout) * 1000;

const UPLOAD = 'https://uploads.github.com/user-attachments/assets';

// The image types GitHub's attachment upload takes, keyed by the extension it
// expects in the file name. The name and the content type travel together in the
// query, so the extension decides the type: a sniffed type that disagreed with
// the name would publish a .png link to JPEG bytes. Video is left out because
// this skill attaches images, and SVG because the broker refuses a document that
// can carry script.
const TYPES = {
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp',
};

// What a successful upload answers with. cli/cli#14495 reports the URL under
// "url", which is not documented, so the value's own shape is what is matched.
const ASSET = /^https:\/\/github\.com\/user-attachments\/assets\/[0-9a-fA-F-]{36}$/;

// writeSync, not console: process.exit can drop a buffered write to a pipe, and
// mint.sh reads this driver's stdout through a command substitution.
function fail(code, message) {
  writeSync(2, `token: ${message}\n`);
  process.exit(code);
}

function succeed(url) {
  writeSync(1, url + '\n');
  process.exit(0);
}

// Run gh and return its trimmed stdout, or null. The token is one of these
// answers, so no caller may put a result in a message or a log.
function gh(args) {
  const result = spawnSync('gh', args, { encoding: 'utf8', timeout: timeoutMs, maxBuffer: 256 * 1024 });
  if (result.error || result.status !== 0) return null;
  return result.stdout.trim() || null;
}

// The type gate comes before the path choice, so an image kind neither path can
// upload leaves the browser drivers free to try: GitHub's editor does paste an
// SVG. Every refusal below this line is about the file itself and stops the run.
const type = TYPES[extname(image).toLowerCase()];
if (!type) {
  fail(9, `${basename(image)} is not a PNG, JPEG, GIF or WebP by name, and GitHub's token upload takes nothing else`);
}

// The broker's mint verb is asked for first. A host that has it holds no token of
// its own -- `gh` there is a shim, and its `auth token` is refused by design --
// so reading a token first would cost a pointless round trip on every run.
if (process.env.ORCA_GH_BROKER_PORT) {
  const minted = spawnSync('gh-mint', [image, '--repo', repo], {
    encoding: 'utf8', timeout: timeoutMs, maxBuffer: 256 * 1024,
  });
  if (minted.error?.code !== 'ENOENT') {
    if (minted.stderr) writeSync(2, minted.stderr);
    if (minted.error) {
      fail(7, minted.error.code === 'ETIMEDOUT'
        ? `gh-mint did not answer within ${timeout}s`
        : `gh-mint could not be run: ${minted.error.code}`);
    }
    const url = (minted.stdout || '').trim();
    if (minted.status === 0 && ASSET.test(url)) succeed(url);
    if (minted.status === 0) fail(8, 'gh-mint returned no attachment URL');
    // gh-mint's own refusals (64) name the file and what to do about it, and
    // burying that behind a later browser failure -- on a host that has no
    // browser -- helps nobody, so this stops rather than falling back.
    if (minted.status === 64) fail(2, 'gh-mint refused the file; see its message above');
    if (minted.status === 77) fail(8, 'the broker holding the token refused this upload');
    fail(7, minted.signal
      ? `gh-mint was killed by ${minted.signal} without an attachment URL`
      : `gh-mint exited ${minted.status} without an attachment URL`);
  }
}

const token = gh(['auth', 'token']);
if (!token) {
  fail(9, 'no gh login here and no broker mint verb, so there is no token to upload with');
}

// The asset is bound to this id at upload time, which is why --repo is required:
// mint against one repository and embed in another and the image 404s for the reader.
const id = gh(['api', `repos/${repo}`, '--jq', '.id']);
if (!id || !/^[0-9]+$/.test(id)) {
  fail(5, `cannot read the numeric id of ${repo}; check the name and that this login can see it`);
}

let bytes;
try { bytes = readFileSync(image); }
catch (error) { fail(2, `cannot read ${image}: ${error.code || error.message}`); }

const query = new URLSearchParams({ name: basename(image), content_type: type, repository_id: id });
let answer;
try {
  answer = await fetch(`${UPLOAD}?${query}`, {
    method: 'POST',
    body: bytes,
    headers: { Authorization: `token ${token}`, 'Content-Type': type, Accept: 'application/vnd.github+json' },
    // Never follow a redirect with the token attached: fetch would re-send the
    // Authorization header to wherever the redirect points.
    redirect: 'manual',
    signal: AbortSignal.timeout(timeoutMs),
  });
} catch (error) {
  fail(7, error.name === 'TimeoutError'
    ? `the upload did not finish within ${timeout}s`
    : `the upload to GitHub did not complete: ${error.message}`);
}

const said = await answer.text().catch(() => '');
const brief = said.replace(/\s+/g, ' ').trim().slice(0, 300);
if (!answer.ok) {
  // A 404 here reads as a missing endpoint and is usually a token this upload
  // does not accept: cli/cli#14309 reports a GitHub App installation token
  // refused with exactly that status.
  fail(8, `GitHub refused the upload: HTTP ${answer.status} ${brief}`);
}

let parsed;
try { parsed = JSON.parse(said); } catch { parsed = null; }
const url = Object.values(parsed && typeof parsed === 'object' ? parsed : {})
  .find(value => typeof value === 'string' && ASSET.test(value));
if (!url) fail(8, `the upload answered without an attachment URL: ${brief}`);
succeed(url);
