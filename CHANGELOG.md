# Changelog

## Unreleased

### Added

- **Token uploads, with no browser at all.** Where a `gh` login is readable, the helper now uploads the image with it in one request, and `--driver auto` tries that before any browser. On an Orca remote host, which holds no GitHub credential, it calls the GitHub broker's `gh-mint` instead, so the machine that does hold the token performs the upload and sends back only the URL. A remote host therefore no longer needs a browser or a signed-in session, which is what made this unusable there (#3).
  Action: Nothing to set up where `gh` is already signed in. The browser drivers stay as the fallback, so keep using `login.sh` for Chrome.

- **Exit code 7 now warns you not to retry blindly.** It means no attachment URL came back and the upload may still have landed, so a retry can leave a second asset behind. Exit code 8 keeps the opposite meaning: refused, and nothing was uploaded (#3).

- **Exit code 9.** The token driver reports 9 when no token upload is available here, or none for this file — an SVG, for instance, which only a browser can paste. `--driver auto` reads it as its cue to fall back to a browser rather than as a failure; `--driver token` shows you the reason (#3).

### Removed

- **PDF uploads.** The helper now uploads images only. A PDF is refused before any browser starts, by its name or its own first bytes, with exit code 2 and a message naming the reason. GitHub's token upload refuses PDFs outright, and a document belongs in a document store you can link to (#19).
  Action: If you were uploading PDFs, store them elsewhere and put the link in your issue or pull request.

### Fixed

- **Bad input reported as bad input.** A `--timeout` that is not a whole number of seconds, and a file that exists but cannot be read, are now named with exit code 2. Both previously reached past the argument checks and came back as a raw interpreter error with exit code 1 (#3).

- **The documented way to check a public attachment URL.** The skill said the plain URL answers `200 image/png`. It answers **302** to a signed S3 URL that expires in 300 seconds, and a `HEAD` gets **403** at that step, so `curl -I` on a perfectly good attachment looked broken (#3).

- **Concurrent Chrome runs.** The Chrome driver now takes an exclusive profile lock so simultaneous runs cannot share one browser, and takes over locks whose process is gone (#17).

- **Chrome port and process cleanup.** The Chrome driver now refuses to attach when port 9375 is already in use and kills the Chrome process it launched on success, failure, and timeout (#15).

- **Chrome discovery on Linux.** The Chrome driver now accepts `GH_ATTACH_CHROME`, finds the usual Chrome and Chromium executables on PATH, and reports exit code 3 with an actionable message when no executable is available (#5).

- **Refused uploads in Chrome.** When GitHub refuses an upload, the Chrome driver now stops at once with exit code 8 and the same message as the Orca driver, instead of waiting for its timeout and reporting a generic failure (#9).

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
