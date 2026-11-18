# Maintainer notes

This file is for maintainers and agents that change this repository. A person who only installs the skill needs the [README](README.md).

## Release

This repository releases by hand:

1. In the release commit, set `metadata.version` in [SKILL.md](SKILL.md) to the new version, and move the CHANGELOG's `Unreleased` entries under a heading for that version.
2. Merge that commit, then tag the commit it produced on `main` as `vMAJOR.MINOR.PATCH` and publish the GitHub release from that tag.

The README install command names no tag, so a release does not change the README.
