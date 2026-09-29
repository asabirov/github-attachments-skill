# Changelog

## Unreleased

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
