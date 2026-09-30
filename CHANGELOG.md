# Changelog

## Unreleased

### Added

- **Uploads without a browser.** Where a `gh` login or the GitHub broker's `gh-mint` is available, the helper uploads the image with it in one request, and `--driver auto` tries that before any browser. A remote host with neither a browser nor a signed-in session can now mint; the browser drivers stay as the fallback (#3).

- **Exit codes 7 and 9.** 7 means the bytes went out and no URL came back, so a retry can leave a second asset behind; 8 now covers every failure where nothing was uploaded and a retry is safe. 9 means there is no token upload here, and tells `--driver auto` to use a browser (#3).

### Removed

- **PDF uploads.** The helper now uploads images only. A PDF is refused before any browser starts, by its name or its own first bytes, with exit code 2 and a message naming the reason. GitHub's token upload refuses PDFs outright, and a document belongs in a document store you can link to (#19).
  Action: If you were uploading PDFs, store them elsewhere and put the link in your issue or pull request.

### Fixed

- **Bad input and attachment checks.** A `--timeout` outside 1 to 3600 seconds and an unreadable file now exit 2 instead of a raw interpreter error, and the documented way to check a public attachment URL is corrected: it answers **302** to a signed S3 URL, and `HEAD` gets **403** at that step (#3).

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
