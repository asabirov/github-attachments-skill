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

// Run gh and hand back the whole result, because the caller has to tell a gh that
// could not run from a gh that ran and said no. One of these answers is the token,
// so a caller may put `stdout` in a header and nowhere else -- not in a message,
// not in a log.
function gh(args) {
  return spawnSync('gh', args, { encoding: 'utf8', timeout: left(), maxBuffer: 256 * 1024 });
}

function oneline(text, limit = 300) {
  return (text || '').replace(/\s+/g, ' ').trim().slice(0, limit);
}

// `--timeout` is the caller's deadline for the whole driver, not for each step. The
// local path makes three calls, so giving each one the full budget would let a slow
// machine take three times what the caller asked for. mint.sh bounds the value; it
// is bounded again here because Node answers an out-of-range timeout with a stack
// trace, and this driver can be run on its own.
const budget = Number(timeout);
if (!Number.isInteger(budget) || budget < 1 || budget > 3600) {
  fail(2, `--timeout wants 1 to 3600 whole seconds, got '${String(timeout).slice(0, 20)}'`);
}
const deadline = Date.now() + budget * 1000;
// 1ms rather than 0 for an exhausted budget: 0 means "no timeout" to spawnSync, and
// AbortSignal.timeout throws on it. A 1ms deadline fails at once, which is wanted.
const left = () => Math.max(1, deadline - Date.now());

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
    encoding: 'utf8', timeout: left(), maxBuffer: 256 * 1024,
  });
  if (minted.error?.code !== 'ENOENT') {
    if (minted.stderr) writeSync(2, minted.stderr);
    if (minted.error) {
      // A kill after the deadline is not the same as never starting: the bytes may
      // already be at the broker, so that one is 7 and this one is 3.
      fail(minted.error.code === 'ETIMEDOUT' ? 7 : 3, minted.error.code === 'ETIMEDOUT'
        ? `gh-mint did not answer within ${budget}s`
        : `gh-mint could not be run: ${minted.error.code}`);
    }
    const url = (minted.stdout || '').trim();
    if (minted.status === 0 && ASSET.test(url)) succeed(url);
    // Exit 0 without a URL is the worst answer of the lot: the asset may well exist
    // and only its URL was lost, so this is 7 rather than 8, and 7 warns that a
    // retry can leave a second asset behind.
    if (minted.status === 0) fail(7, `gh-mint reported success without an attachment URL: ${oneline(url, 120)}`);
    // gh-mint's own refusals (64) name the file and what to do about it, and
    // burying that behind a later browser failure -- on a host that has no
    // browser -- helps nobody, so this stops rather than falling back.
    if (minted.status === 64) fail(2, 'gh-mint refused the file; see its message above');
    if (minted.status === 77) fail(8, 'the broker holding the token refused this upload');
    // 75 is gh-mint failing to encode the file, which it does before sending
    // anything, so nothing can have been uploaded. An exit this driver does not
    // know stays at 7, because an upload cannot be ruled out.
    if (minted.status === 75) fail(3, 'gh-mint could not prepare the file; nothing was sent');
    fail(7, minted.signal
      ? `gh-mint was killed by ${minted.signal} without an attachment URL`
      : `gh-mint exited ${minted.status} without an attachment URL`);
  }
}

// The token is read before anything else: without one there is nothing to do here,
// and that is exit 9 -- a browser's job -- rather than a failure of this path. gh's
// stderr is deliberately not quoted here, being the one answer that carries a
// credential.
const auth = gh(['auth', 'token']);
const token = auth.status === 0 ? auth.stdout.trim() : '';
if (!token) {
  fail(9, 'no gh login here and no broker mint verb, so there is no token to upload with');
}

// The asset is bound to this id at upload time, which is why --repo is required:
// mint against one repository and embed in another and the image 404s for the reader.
// A gh that could not run at all is not the same as a repository this login cannot
// see, and reporting the second for the first sends the reader to check a name that
// was never the problem.
const lookup = gh(['api', `repos/${repo}`, '--jq', '.id']);
// This happens before a single byte is sent, so it is never 7: that code promises
// the upload may have landed, and here there was no upload to land.
if (lookup.error) {
  fail(3, lookup.error.code === 'ETIMEDOUT'
    ? `gh did not answer within ${budget}s when asked for the id of ${repo}`
    : `gh could not be run to read the id of ${repo}: ${lookup.error.code}`);
}
const id = lookup.stdout.trim();
if (!/^[0-9]+$/.test(id)) {
  // Only the status is taken out of gh's answer, never the text. gh's stderr is the
  // one place a credential could surface -- `GH_DEBUG=api` prints request headers --
  // and a 404 against a 403 is all the caller needs to tell a wrong name from a
  // login that cannot see the repository.
  const status = /\b(\d{3})\b/.exec(oneline(lookup.stderr, 200));
  fail(5, `cannot read the numeric id of ${repo}${status ? ` (gh answered HTTP ${status[1]})` : ''}; check the name and that this login can see it`);
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
    signal: AbortSignal.timeout(left()),
  });
} catch (error) {
  // 7, not 3: the request was dispatched, so the bytes may have arrived.
  fail(7, error.name === 'TimeoutError'
    ? `the upload did not finish within ${budget}s`
    : `the upload to GitHub did not complete: ${error.message}`);
}

const said = await answer.text().catch(() => '');
const brief = oneline(said);
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
// GitHub took the bytes and this driver could not find the URL in the answer, so
// the asset probably exists. 7, not 8, for the same reason as gh-mint's silent
// success above: a caller who retries on 8 would mint a second copy unwarned.
if (!url) fail(7, `the upload answered HTTP ${answer.status} without an attachment URL: ${brief}`);
succeed(url);
