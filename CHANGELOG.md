# Changelog

All notable changes to this skill are documented here.

## [0.1.0] - 2026-09-29

- Upload images and PDFs through a signed-in GitHub browser session.
- Return GitHub attachment URLs or Markdown and HTML links.
- Support Orca and Chrome drivers with bounded timeouts and cleanup.
- Validate required arguments, the `owner/name` repository form, that the file exists, and the 10 MB size limit before upload.
- Provide offline tests for CLI validation, polling, paste handling, and driver behavior.
