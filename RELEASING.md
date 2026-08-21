# Releasing

Hex package. Semver. While the version is `0.x`, a breaking change bumps the minor (`0.1.0` → `0.2.0`).

`mix.exs` sets `source_ref: "v#{version}"` and the Changelog package link to that tag. Tag before you publish so HexDocs source links resolve.

## Steps

1. Set `@version` in `mix.exs`.
2. Date the matching heading in `CHANGELOG.md`. Move new notes out of Unreleased.
3. Update the install constraint in `README.md` and `guides/phoenix-integration.md` if the minor changed (`{:enact, "~> 0.1.0"}`).
4. `mix test` and `mix hex.build`.
5. Commit.
6. Tag and push:

   ```bash
   git tag v0.1.0
   git push origin main --follow-tags
   ```

7. Publish package and docs:

   ```bash
   mix hex.publish
   ```

The tag must match `@version` (for `0.1.0`, the tag is `v0.1.0`).
