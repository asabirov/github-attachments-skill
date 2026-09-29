---
name: github-attachments
description: "Attach an image or PDF to a GitHub issue, PR, or comment without committing it to the repository. Returns a GitHub attachment URL; images render inline and PDFs render as download links. Use when a screenshot, a diagram, a before-and-after or any picture belongs in something you are about to file or open. Trigger on: attach a PDF, upload homework files to an issue, attach a screenshot, put this image in the issue, add a picture to the PR, screenshot in the PR body, show the before and after, upload an image to GitHub, embed an image in a comment, the image does not render, my attachment 404s."
metadata:
  version: "0.1.0"
---

# github-attachments

Give the command a file path to get an image or PDF URL for any issue, pull request, or comment in the named repository.

```bash
scripts/mint.sh shot.png --repo example-owner/example-repo
# https://github.com/user-attachments/assets/00000000-0000-4000-8000-000000000000

scripts/mint.sh shot.png --repo example-owner/example-repo --format markdown
gh pr edit 42 --repo example-owner/example-repo --body-file body.md
```

Repository names and attachment IDs in these examples are synthetic placeholders, not live assets.

## Decision

**Use a signed-in browser's paste handler, then return the URL for callers to embed.** Two alternatives were tested and rejected on 2026-09-03.

*Commit the file into the repository* — save it in `.github/pr-screenshots/` and link to the blob. This works with the token every agent already has and would work on CI, which this skill does not. It was rejected because the image would remain in git history forever, even though it describes something true for only one afternoon. Readers outside a private repository would also see nothing.

*Call GitHub's upload endpoint directly* — reproduce the policy, S3 upload, and confirmation sequence used by the web UI. This was rejected because it cannot be authenticated. A request to `POST
github.com/upload/policies/assets` with a personal access token and a real repository ID returned **422** with GitHub's generic error page instead of an upload policy. The endpoint requires a session cookie and a CSRF token. There is no token-based path, so there is no CI path.

That 422 made the browser session the only available key. Let GitHub's editor upload the file and read its textarea.

## Three things that can mislead you

**The URL is a reference, not the file itself.** `github.com/user-attachments/assets/<uuid>` returns **404** for an asset in a private repository, regardless of who requests it. This includes signed-in repository owners. When GitHub renders the URL, it rewrites it to a `private-user-images.githubusercontent.com` URL containing a JWT that expires in about five minutes.

For a **public** repository, the plain URL does fetch the file: `200 image/png`, verified against `cli/cli`. A direct `curl` request therefore proves nothing for a private repository. The reliable check is to read the rendered body:

```bash
gh api repos/OWNER/REPO/pulls/N -H 'Accept: application/vnd.github.html+json' --jq .body_html
```

**The asset belongs to a repository, not to you.** GitHub records the `repository_id` from the paste page during upload, so `--repo` is required and must be correct. If you mint the asset against repository A and embed it in repository B, it renders for you but returns 404 for your reader.

**Do not send the file bytes through a conversation.** `mint.sh` must keep accepting a path and printing a URL. A 416 KB screenshot becomes 554,756 base64 characters—about 150k tokens in an agent's context—to accomplish what a path accomplishes with about 200 tokens. For the same reason, do not `Read` an image before uploading it. You do not need to view it.

## Drivers

`--driver auto` selects the first driver that works.

| Driver | When | Setup |
| --- | --- | --- |
| `orca` | `ORCA_WORKTREE_ID` is set and `orca` is on PATH | Node.js and `file` on PATH; uses the Orca browser session, exits 4 if signed out |
| `chrome` | everywhere else | `scripts/login.sh`, once |

Chrome runs headless without additional dependencies. It uses `GH_ATTACH_CHROME` when set, then looks for `google-chrome`, `google-chrome-stable`, `chromium`, or `chromium-browser` on PATH (and the standard macOS app path). If none is executable, it exits 3 with an actionable message. It uses Node's global `WebSocket` (since v21) to speak the DevTools Protocol. It avoids coupling to another skill's `node_modules` by not importing puppeteer from `browser-tools`. It uses `~/.claude/state/github-attachments/chrome-profile`, not `~/.cache/browser-tools`: every Claude session on this machine shares that cache, so a live GitHub session there would let any session act as you.

Port **9375**, not 9222, avoids other sessions' browsers. Before launch, the driver takes an exclusive lock beside the persistent profile and refuses with exit 3 if another run owns it; a second concurrent run therefore cannot share the browser, even before the port check. A stale lock whose PID is dead is taken over. Stop the process using port 9375 and retry if needed. Each run closes its tab and kills the Chrome process group it launched on success, failure, timeout, SIGINT, SIGTERM, and SIGHUP, and removes its lock. SIGKILL cannot be caught. On Apple silicon, it explicitly starts Chrome as arm64, because an Intel `bash` first on PATH would make macOS run Chrome under Rosetta, where GitHub's page takes tens of seconds per step.

The Orca driver ties upload and cleanup to the page ID it created, checks the target repository URL, and parses only structured result fields. Paste, polling, and draft cleanup happen in one browser evaluation because separate Orca evaluations may lose page state. Node.js builds the request without printing image bytes. Large transfers use bounded arguments; the Chrome driver has no CLI argument transfer.

### PDF documents

Use the same command with a `.pdf` path. Preserve the full PDF URL: `https://github.com/user-attachments/files/<id>/<filename>`. `--format markdown` returns a normal link, and `--format html` returns an anchor. Images continue to render inline. The helper keeps its conservative 10 MB file limit for both images and PDFs.

The Orca driver stages large files in bounded calls within its own tab before pasting. It uses a unique origin-storage key for staging and checks the SHA-256 hash before pasting. Cleanup is retried on exit, with a warning naming the key if it cannot be verified. Browser origin-storage quota can limit large transfers; if staging fails, the driver returns no URL. The Chrome driver does not use this staging path.

### The one manual step

GitHub's upload requires a session, which no script can create: it needs a password and a second factor. `scripts/login.sh` opens a visible Chrome window using this skill's own profile, waits for sign-in to complete, and prints the login it detected. After that, every run is headless and unattended until the session expires. Inside Orca, you never need this step.

## What it refuses, and why it refuses early

These checks happen before a browser starts. An oversized image previously caused a costly failure: it uploaded for a minute and then timed out. GitHub checks the size *after* the transfer, so this skill rejects the file before uploading it.

| Exit | Means |
| --- | --- |
| 2 | bad arguments, missing file, `--repo` not `owner/name`, or over GitHub's 10 MB limit |
| 3 | no browser could be opened, the DevTools port is already in use, or the page did not finish loading within `--timeout` |
| 4 | that browser is not signed in to GitHub |
| 5 | no usable comment editor — repo missing, invisible, or issues disabled; or the box already has text (a saved draft or a prefilled issue template), which is left untouched |
| 6 | the editor ignored the paste |
| 7 | the upload never returned a URL within `--timeout` |
| 8 | GitHub refused the upload, probably because of a rate limit; wait and retry later |

Signed-out status has its own exit code because it looks exactly like a failed upload but has a one-command fix.

## How the upload happens

`lib/paste.js` creates a `File` in the page, places it in a `DataTransfer`, and dispatches a `paste` event to the Markdown editor. GitHub's JavaScript performs the upload and writes the completed reference into the textarea. The reference is read back, and the textarea is cleared so no draft remains.

Both editor types accept a paste. Classic issue and pull-request pages use textareas named `new_comment_field` and `fc-<resource>-body`. The newer `/issues/new` page uses a React editor with a generated ID. `mint.sh` targets `/issues/new` because this page exists in every repository; no issue or pull request needs to exist first.

**`DOM.setFileInputFiles` does not work here**, even though `orca upload` and most CDP recipes use it. GitHub hides its file input from the accessibility tree behind an "Attach files" button, so the element reference never resolves. On `/issues/new`, there is no file input at all. Making the input visible with CSS does not restore it to the accessibility tree. Pasting is therefore the only available route.

## Tests

```bash
tests/mint-cli.test.sh                    # what it refuses, all before a browser starts
tests/polling-survives-uploading.test.sh  # actual driver: page isolation, pending upload, and refusals
node tests/test_paste_lib.mjs             # the paste library against a fake DOM
node --test tests/orca-driver.test.mjs   # PDF/image output, large transfers and cleanup
```

None accesses the network. The polling shell entry point runs the Orca driver suite. Check end-to-end by using the skill: mint an image, put it in a body, and read the rendered body back.
