# Maintainer notes

This file is for maintainers and agents that change this repository. A person who only installs the skill needs the [README](README.md).

## Release

This repository releases by hand, so the step that creates a release tag also updates the README:

1. In the release commit, set `metadata.version` in [SKILL.md](SKILL.md) to the new version, move the CHANGELOG's `Unreleased` entries under a heading for that version, and replace the tag in the README's install command and in its pinned-tag note with the new tag.
2. Merge that commit only when you are ready to tag, then tag the commit it produced on `main` as `vMAJOR.MINOR.PATCH` and publish the GitHub release from that tag.

The README on `main` names the new tag as soon as the release commit lands, so tagging is the next action after the merge and not a later one. The rule comes from [asabirov/better-skill-creator-skill#29](https://github.com/asabirov/better-skill-creator-skill/issues/29).
