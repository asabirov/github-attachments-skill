// Upload the image with a GitHub token instead of a browser session.
//
// Two paths, chosen by asking `gh` for a token: a machine that has one uploads the
// bytes itself, and a machine that has none runs `gh-mint`, which hands them to the
// broker on the machine that does. Exit 9 means neither path is open here, and is
// the only code mint.sh reads as "start a browser instead".
//
// The other codes say whether a retry is safe, so keep them honest when editing:
// 3 nothing was sent, 8 refused and nothing was uploaded, 7 the bytes went out and
// no URL came back, so a retry can leave a second asset behind. When in doubt use 7.

import { readFileSync, writeSync } from 'node:fs';
import { basename, extname } from 'node:path';
import { spawnSync } from 'node:child_process';

const [image, repo, timeout] = process.argv.slice(2);

const UPLOAD = 'https://uploads.github.com/user-attachments/assets';

// The name and the content type travel together in the upload's query, so the
// extension decides the type: sniffing could publish a .png link to JPEG bytes.
const TYPES = {
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp',
};

// The field holding it is undocumented, so a successful upload is matched on shape.
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

// The whole result, because a gh that could not run and a gh that ran and said no
// need different answers. `stdout` here may be the token: header only, never a
// message or a log.
function gh(args) {
  return spawnSync('gh', args, { encoding: 'utf8', timeout: left(), maxBuffer: 256 * 1024 });
}

function oneline(text, limit = 300) {
  return (text || '').replace(/\s+/g, ' ').trim().slice(0, limit);
}

// One deadline for the driver, not one per call, or three slow calls would take
// three times what the caller asked for. Bounded here too, because Node answers an
// out-of-range timeout with a stack trace and this driver can be run on its own.
const budget = Number(timeout);
if (!Number.isInteger(budget) || budget < 1 || budget > 3600) {
  fail(2, `--timeout wants 1 to 3600 whole seconds, got '${String(timeout).slice(0, 20)}'`);
}
const deadline = Date.now() + budget * 1000;
// 1ms, not 0: spawnSync reads 0 as "no timeout" and AbortSignal.timeout throws on it.
const left = () => Math.max(1, deadline - Date.now());

// Before the path choice, so a kind neither path takes still reaches a browser,
// whose editor does paste an SVG. Below this line every refusal stops the run.
const type = TYPES[extname(image).toLowerCase()];
if (!type) {
  fail(9, `${basename(image)} is not a PNG, JPEG, GIF or WebP by name, and GitHub's token upload takes nothing else`);
}

// Asking gh is the only reliable way to tell the two paths apart. ORCA_GH_BROKER_PORT
// looks like the signal and is not: bin/setup renders that port inside the installed
// gh-mint, so no shell ever has it set. Asking gh first also keeps a machine that has
// a token away from a gh-mint that was never given a port. gh's stderr is not read
// here, being the one answer that can carry a credential.
const auth = gh(['auth', 'token']);
// A hung gh has eaten the deadline; going on would blame gh-mint for its silence.
// A gh that is absent or refuses is the ordinary "no token here" and falls through.
if (auth.error?.code === 'ETIMEDOUT') {
  fail(3, `gh did not answer within ${budget}s when asked for a token`);
}
const token = auth.status === 0 ? auth.stdout.trim() : '';

// No token here, so the broker on the machine that has one does the upload. It takes
// a path and returns a URL; this host never holds a credential.
if (!token) {
  const minted = spawnSync('gh-mint', [image, '--repo', repo], {
    encoding: 'utf8', timeout: left(), maxBuffer: 256 * 1024,
  });
  // Neither a token nor a way to reach one, so `auto` may try a browser.
  if (minted.error?.code === 'ENOENT') {
    fail(9, 'no gh login here, and no gh-mint to reach the broker that holds one');
  }
  if (minted.stderr) writeSync(2, minted.stderr);
  if (minted.error) {
    // These two are the only codes spawnSync invents for a child it started and then
    // killed, so the file may already be at the broker. Every other code is fork or
    // exec failing. Keep the test this way round: it needs no errno catalogue.
    const ran = ['ETIMEDOUT', 'ENOBUFS'].includes(minted.error.code);
    fail(ran ? 7 : 3,
      minted.error.code === 'ETIMEDOUT' ? `gh-mint did not answer within ${budget}s`
        : ran ? `gh-mint was stopped while running (${minted.error.code}); the upload may still have happened`
        : `gh-mint could not be run: ${minted.error.code}`);
  }
  const url = (minted.stdout || '').trim();
  if (minted.status === 0 && ASSET.test(url)) succeed(url);
  // Success with no URL: the asset probably exists and only its URL was lost.
  if (minted.status === 0) fail(7, `gh-mint reported success without an attachment URL: ${oneline(url, 120)}`);
  // 64 is gh-mint's own refusal of the file. Its message says what to do, and on a
  // host with no browser, hiding that behind a browser failure helps nobody.
  if (minted.status === 64) fail(2, 'gh-mint refused the file; see its message above');
  if (minted.status === 77) fail(8, 'the broker holding the token refused this upload');
  // 75 is gh-mint failing to encode the file, which it does before sending anything.
  // 69 stays at 7 below: it means an unset port, which sends nothing, but also no
  // answer and a malformed answer, which come after the bytes have gone.
  if (minted.status === 75) fail(3, 'gh-mint could not prepare the file; nothing was sent');
  fail(7, minted.signal
    ? `gh-mint was killed by ${minted.signal} without an attachment URL`
    : `gh-mint exited ${minted.status} without an attachment URL`);
}

// The asset is bound to this id at upload time, which is why --repo must be right:
// mint against one repository and embed in another and the image 404s for the reader.
const lookup = gh(['api', `repos/${repo}`, '--jq', '.id']);
// Nothing has been sent yet, so these are 3 and never 7.
if (lookup.error) {
  fail(3, lookup.error.code === 'ETIMEDOUT'
    ? `gh did not answer within ${budget}s when asked for the id of ${repo}`
    : `gh could not be run to read the id of ${repo}: ${lookup.error.code}`);
}
const id = lookup.stdout.trim();
if (!/^[0-9]+$/.test(id)) {
  // Only the status is taken from gh's stderr, never the text: `GH_DEBUG=api` prints
  // request headers there. Anchored to `HTTP` so a `per_page=100` is not read as one.
  const status = /\bHTTP\/?[\d.]*\s*(\d{3})\b/i.exec(oneline(lookup.stderr, 200));
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
    // Never follow a redirect while the token is attached: fetch would re-send the
    // Authorization header to wherever the redirect points.
    redirect: 'manual',
    signal: AbortSignal.timeout(left()),
  });
} catch (error) {
  // A connection never made sent nothing, so it is 3. Anything else may have reached
  // GitHub, including a cause not named here.
  const unreached = ['ENOTFOUND', 'EAI_AGAIN', 'ECONNREFUSED', 'EHOSTUNREACH',
    'ENETUNREACH', 'ENETDOWN', 'ETIMEDOUT', 'UND_ERR_CONNECT_TIMEOUT'].includes(error.cause?.code);
  fail(unreached ? 3 : 7,
    error.name === 'TimeoutError' ? `the upload did not finish within ${budget}s`
      : unreached ? `could not reach ${new URL(UPLOAD).host}: ${error.cause.code}`
      : `the upload to GitHub did not complete: ${error.message}`);
}

const said = await answer.text().catch(() => '');
const brief = oneline(said);
if (!answer.ok) {
  // A 404 here is usually a token this endpoint does not accept, not a missing
  // endpoint: installation tokens are refused with exactly that status.
  fail(8, `GitHub refused the upload: HTTP ${answer.status} ${brief}`);
}

let parsed;
try { parsed = JSON.parse(said); } catch { parsed = null; }
const url = Object.values(parsed && typeof parsed === 'object' ? parsed : {})
  .find(value => typeof value === 'string' && ASSET.test(value));
// GitHub took the bytes, so the asset probably exists even though its URL was lost.
if (!url) fail(7, `the upload answered HTTP ${answer.status} without an attachment URL: ${brief}`);
succeed(url);
