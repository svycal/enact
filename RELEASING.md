# Releasing

Releases are run by the `release` agent skill in [`.agents/skills/release`](.agents/skills/release/SKILL.md). In Claude Code, run `/release`. Other agents can be pointed at the skill file.

The skill picks the version from the `Unreleased` changelog entries, bumps it, runs the checks, and commits. It then stops for your approval before pushing and tagging. You run `mix hex.publish` yourself, since it needs your Hex credentials. After you confirm the publish, the skill creates the GitHub release.

## Manual

Hex package. Semver. While the version is `0.x`, a breaking change bumps the minor (`0.1.0` → `0.2.0`).

`mix.exs` sets `source_ref: "v#{version}"` and the Changelog package link to that tag. Tag before you publish so HexDocs source links resolve.

1. Make sure `main` is clean and up to date, CI is passing, and every user-facing change since the last tag is under `## Unreleased` in `CHANGELOG.md`.
2. Set `@version` in `mix.exs`.
3. Change the `## Unreleased` heading in `CHANGELOG.md` to `## X.Y.Z (YYYY-MM-DD)`.
4. Update the install constraint in `README.md` and `guides/phoenix-integration.md` if the minor changed (`{:enact, "~> 0.1.0"}`).
5. `mix test` and `mix hex.build`.
6. Commit as `Release X.Y.Z`.
7. Tag and push:

   ```bash
   git tag v0.1.0
   git push origin main --follow-tags
   ```

8. Publish package and docs:

   ```bash
   mix hex.publish
   ```

9. Create a GitHub release for the tag, titled `Version X.Y.Z`, with that version's `CHANGELOG.md` section as the notes.

The tag must match `@version` (for `0.1.0`, the tag is `v0.1.0`).
