# github-attachments

Upload images to GitHub issues, pull requests, and comments from an AI coding agent or the terminal—without committing them to the repository.

```text
Workflow diagram
Local file → GitHub token → GitHub attachment URL → issue, PR, or comment
```

## Quick start

You need Bash, Node.js 21 or later, and either:

- A `gh` login on this machine.
- The GitHub broker's `gh-mint` command, which sends the file to another machine that holds the GitHub token.

The tool has no npm dependencies and works on a headless host.

Clone `asabirov/github-attachments-skill` and run commands from the repository root. To use it from an agent, expose the checkout as the `github-attachments` skill. The agent instructions are in [SKILL.md](SKILL.md). The skill version is in `metadata.version` in [SKILL.md](SKILL.md).

```bash
# Uploads a local file to GitHub. Replace the path and repository first.
scripts/mint.sh screenshot.png --repo example-owner/example-repo --format markdown
```

The command uploads the file and prints Markdown for an issue, pull request, or comment in the same repository. It does not submit the issue or comment.

Example output (synthetic ID, not a live attachment):

```markdown
![screenshot](https://github.com/user-attachments/assets/00000000-0000-4000-8000-000000000000)
```

Run `scripts/mint.sh --help` for the current options and defaults.

## Why it exists

Screenshots can help explain a review but do not belong in the repository's Git history. This helper uploads a local image and returns a GitHub attachment URL, so an agent or developer can add visual evidence without sending the file through the conversation.

Version 0.1.0 drove a signed-in browser and pasted the file into GitHub's own editor, because that was then the only route this skill had; the 422 that proved it is in #3 and in this repository's git history. GitHub's token upload does it in one request, so the browser drivers are gone.

## Limits and authentication

See [SKILL.md](SKILL.md) for supported files, authentication routes, limits, exit codes, and upload behavior.

## Tests and contributions

Run the offline test suite from the repository root:

```bash
tests/mint-cli.test.sh
```

It uses synthetic fixtures and does not upload files or contact GitHub. To check a real upload, mint an image, embed its URL, and read the rendered body back.

For changes, open an issue, work on a branch, run the tests, and submit a pull request. Keep credentials and private attachments out of the repository.

## Release

This repository releases by hand, so the step that creates a release tag also updates the README:

1. In the release commit, set `metadata.version` in [SKILL.md](SKILL.md) to the new version, move the CHANGELOG's `Unreleased` entries under a heading for that version, and replace the tag in the install command and in the pinned-tag note below with the new tag.
2. Merge that commit only when you are ready to tag, then tag the commit it produced on `main` as `vMAJOR.MINOR.PATCH` and publish the GitHub release from that tag.

The README on `main` names the new tag as soon as the release commit lands, so tagging is the next action after the merge and not a later one. The rule comes from [asabirov/better-skill-creator-skill#29](https://github.com/asabirov/better-skill-creator-skill/issues/29).

## Install, update, roll back, and remove

Install the tagged skill with:

```bash
DO_NOT_TRACK=1 npx skills add https://github.com/asabirov/github-attachments-skill/tree/v0.2.0 --skill github-attachments --agent claude-code codex --global
```

`DO_NOT_TRACK=1` tells the skills CLI not to send telemetry. The `npx skills` installer requires Node.js/npm and Git. Update to a later release tag with the same command and its new tag. Roll back by rerunning it with the previous release tag. Remove it with:

```bash
DO_NOT_TRACK=1 npx skills remove github-attachments --agent claude-code codex --global
```

If you prefer not to use `npx skills`, install from a checkout or a Git submodule pinned to the `v0.2.0` release tag, then expose that checkout as the `github-attachments` skill. To update or roll back, check out another release tag. To remove it, delete the link or submodule.

## License

[MIT](LICENSE), copyright 2026 Artur Sabirov.
