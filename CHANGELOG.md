# Changelog

## Unreleased

### Added

- **Uploads without a browser.** Where a `gh` login or the GitHub broker's `gh-mint` is available, the helper uploads the image with it in one request. A host with no browser, no display and no signed-in session can mint (#3).

- **Exit codes 7 and 9.** 7 means the bytes went out and no URL came back, so a retry can leave a second asset behind. 8 covers every failure where nothing was uploaded and a retry is safe. 9 means this machine cannot mint this file: it has no `gh` login and no `gh-mint`, or the file is not named PNG, JPEG, GIF or WebP (#3, #22).

### Removed

- **The browser upload drivers.** Every upload now goes through a `gh` login or `gh-mint`, so `--driver chrome` and `--driver orca` are gone, along with the Chrome profile and its lock, port 9375, the paste library, the one-time `scripts/login.sh` sign-in, exit codes 3 to 6, and the unreleased fixes made to them (#5, #9, #15, #17). Nothing needs a browser, a display or a signed-in session any more (#22).
  Action: On a machine with neither a `gh` login nor `gh-mint`, install one of them. If you pinned `--driver chrome` or `--driver orca`, drop the flag; both now exit 2 with a message naming the removal. If you signed in with 0.1.0, delete `~/.claude/state/github-attachments/chrome-profile`: it holds a live GitHub session that nothing uses, refreshes or clears now.

- **SVG and video uploads.** A browser could paste anything GitHub's editor accepted. The token upload takes PNG, JPEG, GIF and WebP, and nothing this skill is for needs the other two (#22).
  Action: Render a diagram to PNG instead of SVG before minting it.

- **PDF uploads.** The helper now uploads images only. A PDF is refused before any upload, by its name or its own first bytes, with exit code 2 and a message naming the reason. GitHub's token upload refuses PDFs outright, and a document belongs in a document store you can link to (#19).
  Action: If you were uploading PDFs, store them elsewhere and put the link in your issue or pull request.

### Fixed

- **A `gh-mint` that stored nothing.** When the broker's mint exits 75 (nothing sent, or GitHub answered 4xx), the helper now exits 8, so a caller knows a retry is safe. It used to exit 7, which told the caller not to retry. A 76 (the image may already be on GitHub) still exits 7, and both messages now say which case it is (#23).

- **A value flag with no value.** `--repo`, `--alt`, `--format`, `--driver` and `--timeout` given with nothing after them now exit 2 and name the flag. Each one read an unset argument under `set -u` and exited 1 with bash's own `$2: unbound variable`. The exit table in SKILL.md is corrected too: `gh-mint` refusing a file is an exit 2, not an exit 8 (#25).

- **Bad input and attachment checks.** A `--timeout` outside 1 to 3600 seconds and an unreadable file now exit 2 instead of a raw interpreter error, and the documented way to check a public attachment URL is corrected: it answers **302** to a signed S3 URL, and `HEAD` gets **403** at that step (#3).

## 0.1.0 — 2026-09-29

This skill lets AI coding agents and terminal users upload images and PDFs to GitHub issues, pull requests, and comments without committing files to the repository.

### Added

- **Image and PDF uploads.** You can upload a local image or PDF to a GitHub issue, pull request, or comment and receive its attachment URL. This keeps temporary evidence out of the repository.

- **Formatted results.** You can request Markdown or HTML output; images appear inline and PDFs appear as links. This makes the result ready to place in GitHub.

- **Browser selection.** With the default `--driver auto` option you get Orca's browser when you work inside Orca, and Chrome elsewhere. This chooses the browser that matches your working environment.
  Action: Inside Orca, make sure Orca's browser is signed in to GitHub.

- **Chrome uploads on macOS.** You can upload through Chrome on macOS when you are not working inside Orca. This gives you a supported browser option outside Orca.
  Action: If you use Chrome, sign in once with the login script, then sign in again when your GitHub session expires.

- **Early validation.** You get an error before any browser starts when the file is missing, the repository is not in `owner/name` form, or the file is over 10 MB. This prevents an avoidable browser session.
