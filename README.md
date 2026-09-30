# github-attachments

Upload images to GitHub issues, pull requests, and comments from an AI coding agent or the terminal—without committing the files to the repository.

```text
Workflow diagram
Local file → a GitHub token, or a signed-in browser → GitHub attachment URL → issue, PR, or comment
```

## Quick start

You need Bash, Node.js 21 or later, and one way to reach GitHub:

- A `gh` login on this machine. No setup or browser is needed.
- On an Orca remote host, the GitHub broker's `gh-mint` command. The host has no credential: it sends the bytes to the machine that does, which uploads them and returns the URL.
- Orca with a signed-in GitHub browser session.
- Google Chrome on macOS or Linux.

The first two work without a display, so they are the only options for a headless host. The Orca driver also needs the `file` utility on `PATH` to detect the MIME type.
The tool has no npm dependencies. On macOS, the Chrome driver tries the standard application path. On Linux, set `GH_ATTACH_CHROME` to the Chrome executable or let the driver find `google-chrome`, `google-chrome-stable`, `chromium`, or `chromium-browser` on PATH.

Clone `asabirov/github-attachments-skill` and run the commands from the repository root. To use it from an agent, expose the checkout as the `github-attachments` skill. The agent instructions are in [SKILL.md](SKILL.md).
The skill version lives in `metadata.version` in [SKILL.md](SKILL.md).

```bash
# Outside Orca: opens Chrome for a one-time GitHub sign-in.
scripts/login.sh

# Uploads a local file to GitHub. Replace the path and repository first.
scripts/mint.sh screenshot.png --repo example-owner/example-repo --format markdown
```

`login.sh` is only for the Chrome fallback. Skip it when a `gh` login or the broker's `gh-mint` is available. Also skip it inside Orca, which already has a signed-in browser session.

The command uploads the file and prints Markdown that you can paste into an issue, pull request, or comment in the same repository. It does not submit the issue or comment.

Example output (synthetic ID, not a live attachment):

```markdown
![screenshot](https://github.com/user-attachments/assets/00000000-0000-4000-8000-000000000000)
```

By default, the command prints a URL. Use the following options when you need a different format or upload behavior:

- `--format markdown` or `--format html` returns an embeddable link.
- `--alt` sets the alternative text for the link.
- `--driver token|orca|chrome` pins one driver instead of letting `auto` choose.
- `--timeout` sets the upload wait time in seconds. The default is `60`.

## Why it exists

Screenshots are often useful in a review discussion but do not belong in the repository's Git history. This helper accepts a local image and returns a GitHub attachment URL, allowing an agent or developer to add visual evidence without sending the file bytes through the conversation.

When a token is available, the helper uploads the file in one request. Otherwise, it uses GitHub's paste handler in a signed-in browser. The returned link can go in an issue, pull request, or comment; the caller decides where.

## Limits and authentication

- You need write access to the target repository, provided by a `gh` login (or the broker's `gh-mint`) or by a signed-in browser. Browser uploads also require the repository's issue editor to be enabled.
- Token uploads support PNG, JPEG, GIF, and WebP, identified from the file name. Other image types use a browser, which can paste them.
- Upload the file to the repository where you will use the link. Private image references may require GitHub's rendered page to display correctly, so a direct fetch is not a reliable verification method.
- Images only. A PDF is refused before any browser starts, by its name or its first bytes; keep documents in a document store and link to them.
- Files are limited to 10 MB. Orca stages large files in browser origin storage, so browser quota can limit uploads. Chrome transfers files through the DevTools Protocol.
- Chrome stores its signed-in profile outside the checkout at `~/.claude/state/github-attachments/chrome-profile`. Keep this profile private.

For driver behavior, cleanup, and exit codes, see [SKILL.md](SKILL.md).

## Tests and contributions

Run the offline test suites from the repository root:

```bash
tests/mint-cli.test.sh
tests/polling-survives-uploading.test.sh
node tests/test_paste_lib.mjs
node --test tests/orca-driver.test.mjs
```

The polling shell entry point also runs the Orca driver suite. These tests use synthetic fixtures: they do not upload files or contact GitHub. Browser compatibility with the live GitHub editor requires a separate check against GitHub's current behavior.

For changes, open an issue, work on a branch, run the tests, and submit a pull request. Keep credentials, browser profiles, and private attachments out of the repository.

## Install, update, roll back, and remove

Install the tagged skill with:

```bash
DO_NOT_TRACK=1 npx skills add https://github.com/asabirov/github-attachments-skill/tree/v0.1.0 --skill github-attachments --agent claude-code codex --global
```

`DO_NOT_TRACK=1` tells the skills CLI not to send telemetry. The `npx skills` installer requires Node.js/npm and Git. Update to a later release tag with the same command and its new tag. Roll back by rerunning it with the previous release tag. Remove it with:

```bash
DO_NOT_TRACK=1 npx skills remove github-attachments --agent claude-code codex --global
```

If you prefer not to use `npx skills`, install from a checkout or a Git submodule pinned to the `v0.1.0` release tag, then expose that checkout as the `github-attachments` skill; to update or roll back, check out another release tag, and to remove it, delete the link or submodule.

## License

[MIT](LICENSE), copyright 2026 Artur Sabirov.
