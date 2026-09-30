---
name: github-attachments
description: "Attach an image to a GitHub issue, PR, or comment without committing it to the repository. Returns a GitHub attachment URL that renders inline. Use when a screenshot, a diagram, a before-and-after or any picture belongs in something you are about to file or open. Trigger on: attach a screenshot, put this image in the issue, add a picture to the PR, screenshot in the PR body, show the before and after, upload an image to GitHub, embed an image in a comment, the image does not render, my attachment 404s."
metadata:
  version: "0.1.0"
---

# github-attachments

Give `mint.sh` a file path to get an image URL for an issue, pull request, or comment in the named repository.

```bash
scripts/mint.sh shot.png --repo example-owner/example-repo
# https://github.com/user-attachments/assets/00000000-0000-4000-8000-000000000000

scripts/mint.sh shot.png --repo example-owner/example-repo --format markdown
gh pr edit 42 --repo example-owner/example-repo --body-file body.md
```

Repository names and attachment IDs in these examples are synthetic placeholders, not live assets.

## Decision

**Upload with a GitHub token in one request.** This is the only supported path. The URL is returned to the caller for embedding.

The token can come from a local `gh` login or from `gh-mint`, a broker helper that sends the file to another machine holding the GitHub token. No browser, display, or manual sign-in is needed.

*Commit the file into the repository* — save it in `.github/pr-screenshots/` and link to the blob. Rejected because the image would stay in git history forever, even though it describes something that was true for one afternoon. Readers outside a private repository would also see nothing.

*Drive a signed-in browser and paste the file into GitHub's own editor.* That was the design before GitHub's token upload existed, and it cost about 1,200 lines: headless Chrome, a profile holding a live GitHub session, a lock, and a sign-in a person had to do by hand. Removed in #22, once the token path worked on every machine that needs it. A browser could paste an SVG or a video and a token upload cannot; nothing this skill is for needs either.

## Three things that can mislead you

**The URL is a reference, not the file itself.** `github.com/user-attachments/assets/<uuid>` returns **404** for an asset in a private repository, regardless of who requests it, and for an asset that nothing references yet. Therefore, a `curl` immediately after minting can look like a failure. Mint the asset, embed the URL, then check it. When GitHub renders the URL, it rewrites it to a `private-user-images.githubusercontent.com` URL containing a JWT that expires in about five minutes.

Once the URL is referenced in a **public** repository, it fetches the file through a **302** redirect to a signed S3 URL. A `HEAD` request gets **403** at that step, so `curl -I` can look broken even when the attachment works. Read the rendered body instead:

```bash
gh api repos/OWNER/REPO/pulls/N -H 'Accept: application/vnd.github.html+json' --jq .body_html
```

**The asset belongs to a repository, not to you.** GitHub records the `repository_id` from the upload query, so `--repo` is required and must be correct. If you mint the asset for repository A and embed it in repository B, it may render for you but return 404 for the reader.

**Do not send file bytes through the conversation.** `mint.sh` must receive a path and print a URL. A 416 KB screenshot becomes 554,756 base64 characters—about 150k tokens—while a path uses about 200 tokens. For the same reason, do not `Read` an image before uploading it.

## What it needs on the machine

Bash, Node.js 21 or later, and one of these token routes:

| Route | What happens |
| --- | --- |
| a `gh` login | `mint.sh` uploads the bytes itself |
| the broker's `gh-mint` | the machine holding the token uploads them |

The script checks for a `gh` token and otherwise uses `gh-mint`. A host needs one route and nothing else.

It accepts PNG, JPEG, GIF and WebP. The type is chosen from the file name and checked against the first bytes before upload, so a misleading symlink cannot publish another type. `--timeout` limits the run, except that `gh-mint` receives at least 150s, and `--timeout` when that is longer, because the broker behind it can take 120.

`--driver` has one value, `token`, which is also what `auto` selects. `--driver chrome` and `--driver orca` exit 2 because browser drivers were removed.

## What it refuses, and why it refuses early

These checks happen before upload. An oversized image used to upload for a minute and then time out. Because GitHub checks size after transfer, this skill rejects it first.

A PDF is refused by its name and then by its first bytes, so a PDF without a suffix is also caught. This skill uploads images, and a document belongs in a document store that you can link to. GitHub's token upload refuses a PDF as well — a `422`, measured in #3 — but that arrives as an exit 8 the caller has to interpret, and only after the bytes have left the machine.

| Exit | Means |
| --- | --- |
| 2 | bad arguments, a value flag with no value, a missing or unreadable file, `--repo` not `owner/name`, a `--timeout` outside 1 to 3600 whole seconds, a removed `--driver`, a PDF, over GitHub's 10 MB limit, bytes that do not match the name's type, or `gh-mint` refusing the file |
| 7 | the bytes went out and no URL came back, so the upload may have succeeded and retrying may create a second asset. A `5xx` from GitHub counts because it can arrive after storage |
| 8 | the upload failed before anything was stored, so retrying is safe: GitHub refused it, the broker would not run the upload, or `gh` could not read the repository |
| 9 | this machine has no token route for this file: no `gh` login and no `gh-mint`, or a name that is not PNG, JPEG, GIF or WebP |

Exit 9 is a plain failure. Its message identifies whether the problem is the missing token route or the unsupported file name.

## Tests

```bash
tests/mint-cli.test.sh   # what it refuses, all before anything is uploaded
```

The test does not access the network. For an end-to-end check, mint an image, put its URL in a body, and read the rendered body back.
