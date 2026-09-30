---
name: github-attachments
description: "Attach an image to a GitHub issue, PR, or comment without committing it to the repository. Returns a GitHub attachment URL that renders inline. Use when a screenshot, a diagram, a before-and-after or any picture belongs in something you are about to file or open. Trigger on: attach a screenshot, put this image in the issue, add a picture to the PR, screenshot in the PR body, show the before and after, upload an image to GitHub, embed an image in a comment, the image does not render, my attachment 404s."
metadata:
  version: "0.1.0"
---

# github-attachments

Give the command a file path to get an image URL for any issue, pull request, or comment in the named repository.

```bash
scripts/mint.sh shot.png --repo example-owner/example-repo
# https://github.com/user-attachments/assets/00000000-0000-4000-8000-000000000000

scripts/mint.sh shot.png --repo example-owner/example-repo --format markdown
gh pr edit 42 --repo example-owner/example-repo --body-file body.md
```

Repository names and attachment IDs in these examples are synthetic placeholders, not live assets.

## Decision

**Upload with a token where there is one, and fall back to a signed-in browser's paste handler.** Either way the URL goes back to the caller to embed.

*Commit the file into the repository* — save it in `.github/pr-screenshots/` and link to the blob. Rejected because the image would remain in git history forever, even though it describes something true for only one afternoon. Readers outside a private repository would also see nothing.

*Drive a browser and nothing else.* That was the design until GitHub's token upload arrived; `lib/paste.js` holds the 422 that made a browser the only key at the time. The token upload takes images only, so a browser is still the fallback.

## Three things that can mislead you

**The URL is a reference, not the file itself.** `github.com/user-attachments/assets/<uuid>` returns **404** for an asset in a private repository, regardless of who requests it, and for any asset nothing references yet — so a `curl` straight after minting looks like a failure and is not one. Mint, embed, then check. When GitHub renders the URL, it rewrites it to a `private-user-images.githubusercontent.com` URL containing a JWT that expires in about five minutes.

Once it is referenced in a **public** repository the plain URL fetches the file through a **302** to a signed S3 URL, and a `HEAD` gets **403** at that step, so `curl -I` on a good attachment looks broken. The reliable check is to read the rendered body:

```bash
gh api repos/OWNER/REPO/pulls/N -H 'Accept: application/vnd.github.html+json' --jq .body_html
```

**The asset belongs to a repository, not to you.** GitHub records the `repository_id` at upload time — from the paste page, or from the token upload's query — so `--repo` is required and must be correct. If you mint the asset against repository A and embed it in repository B, it renders for you but returns 404 for your reader.

**Do not send the file bytes through a conversation.** `mint.sh` must keep accepting a path and printing a URL. A 416 KB screenshot becomes 554,756 base64 characters—about 150k tokens in an agent's context—to accomplish what a path accomplishes with about 200 tokens. For the same reason, do not `Read` an image before uploading it. You do not need to view it.

## Drivers

`--driver auto` selects the first driver that works.

| Driver | When | Setup |
| --- | --- | --- |
| `token` | a `gh` login, or the broker's `gh-mint`, is on this machine | none |
| `orca` | no token, `ORCA_WORKTREE_ID` is set and `orca` is on PATH | Node.js and `file` on PATH; uses the Orca browser session, exits 4 if signed out |
| `chrome` | no token, and Orca is not there | `scripts/login.sh`, once |

The token driver opens no browser, so it is the only one that works on a machine with no display. Where `gh` has a login it uploads the file itself; where it has none it runs `gh-mint <file> --repo OWNER/REPO`, and the broker on the machine that holds the token uploads for it. A host needs one of those two and nothing else. It takes PNG, JPEG, GIF and WebP by file name, and anything else it leaves to a browser. `--timeout` bounds the whole driver.

Chrome runs headless without additional dependencies. It uses `GH_ATTACH_CHROME` when set, then looks for `google-chrome`, `google-chrome-stable`, `chromium`, or `chromium-browser` on PATH (and the standard macOS app path). If none is executable, it exits 3 with an actionable message. It uses Node's global `WebSocket` (since v21) to speak the DevTools Protocol. It avoids coupling to another skill's `node_modules` by not importing puppeteer from `browser-tools`. It uses `~/.claude/state/github-attachments/chrome-profile`, not `~/.cache/browser-tools`: every Claude session on this machine shares that cache, so a live GitHub session there would let any session act as you.

Port **9375**, not 9222, avoids other sessions' browsers. Before launch, the driver takes an exclusive lock beside the persistent profile and refuses with exit 3 if another run owns it; a second concurrent run therefore cannot share the browser, even before the port check. A stale lock whose PID is dead is taken over. Stop the process using port 9375 and retry if needed. Each run closes its tab and kills the Chrome process group it launched on success, failure, timeout, SIGINT, SIGTERM, and SIGHUP, and removes its lock. SIGKILL cannot be caught. On Apple silicon, it explicitly starts Chrome as arm64, because an Intel `bash` first on PATH would make macOS run Chrome under Rosetta, where GitHub's page takes tens of seconds per step.

The Orca driver ties upload and cleanup to the page ID it created, checks the target repository URL, and parses only structured result fields. Paste, polling, and draft cleanup happen in one browser evaluation because separate Orca evaluations may lose page state. Node.js builds the request without printing image bytes. Large transfers use bounded arguments; the Chrome driver has no CLI argument transfer.

It stages large files in bounded calls within its own tab before pasting, under a unique origin-storage key, and checks their SHA-256 hash before the paste. Cleanup is retried on exit, with a warning naming the key if it cannot be verified. Browser origin-storage quota can limit large transfers; if staging fails, the driver returns no URL.

### The one manual step

Only the browser drivers need this. A browser upload requires a GitHub session, which no script can create: it needs a password and a second factor. `scripts/login.sh` opens a visible Chrome window using this skill's own profile, waits for sign-in to complete, and prints the login it detected. After that, every run is headless and unattended until the session expires. Inside Orca, you never need this step.

## What it refuses, and why it refuses early

These checks happen before a browser starts. An oversized image previously caused a costly failure: it uploaded for a minute and then timed out. GitHub checks the size *after* the transfer, so this skill rejects the file before uploading it.

A PDF is refused the same way, by its name and then by its own first bytes, so a PDF saved without a suffix is caught too. This skill uploads images; GitHub's token upload refuses PDFs outright, and a document belongs in a document store you can link to rather than in an attachment. Letting one through would not be a harmless no-op: GitHub takes the upload and hands back a `user-attachments/files/` URL this skill no longer reads, so the caller would pay the whole transfer and then wait out `--timeout`. Nothing else about a file's type is checked.

| Exit | Means |
| --- | --- |
| 2 | bad arguments, a missing or unreadable file, `--repo` not `owner/name`, a `--timeout` outside 1 to 3600 whole seconds, a PDF, or over GitHub's 10 MB limit |
| 3 | no browser could be opened, the DevTools port is already in use, or the page did not finish loading within `--timeout` |
| 4 | that browser is not signed in to GitHub |
| 5 | no usable comment editor — repo missing, invisible, or issues disabled; or the box already has text (a saved draft or a prefilled issue template), which is left untouched |
| 6 | the editor ignored the paste |
| 7 | no URL came back after the bytes went out, so the upload may have landed: retrying can leave a second asset behind |
| 8 | the upload failed and nothing was uploaded, so a retry is safe: GitHub or the broker refused it, or `gh` could not read the repository |
| 9 | no token upload here, or not for this file; `auto` reads this as its cue to start a browser |

Signed-out status has its own exit code because it looks exactly like a failed upload but has a one-command fix.

## How a browser upload happens

This is the fallback path; the token driver above sends one request instead. `lib/paste.js` creates a `File` in the page, places it in a `DataTransfer`, and dispatches a `paste` event to the Markdown editor. GitHub's JavaScript performs the upload and writes the completed reference into the textarea. The reference is read back, and the textarea is cleared so no draft remains.

Both editor types accept a paste. Classic issue and pull-request pages use textareas named `new_comment_field` and `fc-<resource>-body`. The newer `/issues/new` page uses a React editor with a generated ID. `mint.sh` targets `/issues/new` because this page exists in every repository; no issue or pull request needs to exist first.

**`DOM.setFileInputFiles` does not work here**, even though `orca upload` and most CDP recipes use it. GitHub hides its file input from the accessibility tree behind an "Attach files" button, so the element reference never resolves. On `/issues/new`, there is no file input at all. Making the input visible with CSS does not restore it to the accessibility tree. Pasting is therefore the only available route.

## Tests

```bash
tests/mint-cli.test.sh                    # what it refuses, all before a browser starts
tests/polling-survives-uploading.test.sh  # actual driver: page isolation, pending upload, and refusals
node tests/test_paste_lib.mjs             # the paste library against a fake DOM
node --test tests/orca-driver.test.mjs   # image output, large transfers and cleanup
```

None accesses the network. The polling shell entry point runs the Orca driver suite. Check end-to-end by using the skill: mint an image, put it in a body, and read the rendered body back.
