---
name: release
description: Cut a new release of the enact Hex package. Picks the version from the Unreleased changelog entries, bumps it, commits, pushes, tags, and creates the GitHub release once the maintainer has published to Hex. Use when asked to prepare, cut, or ship a release.
disable-model-invocation: true
---

# Release

Releases are a single "Release X.Y.Z" commit on `main`, a lightweight
`vX.Y.Z` tag, a Hex publish, and a GitHub release whose notes are that
version's changelog section. Stop at each **checkpoint** below and wait for
the maintainer before continuing.

## 1. Check the starting state

```sh
git status -sb
git log --oneline $(git describe --tags --abbrev=0)..HEAD
gh run list --branch main --limit 3
```

- Be on `main`, clean, and up to date with `origin/main`.
- CI on `main` should be green.
- `CHANGELOG.md` must have a `## Unreleased` section covering the commits
  since the last tag. If a user-facing change is missing from it, stop and
  say so rather than writing the entry yourself.

## 2. Pick the version

Read the `## Unreleased` entries and apply semver to the current
`@version` in `mix.exs`. While the version is `0.x`:

- A breaking change or anything added (a new callback, function, option,
  or `Enact.Error` type): minor (0.3.0 → 0.4.0). A new error type is
  breaking, because host renderers must add a clause for it.
- Only fixes: patch (0.3.0 → 0.3.1).
- `1.0.0`: don't pick this yourself; ask.

State the version you chose and why.

## 3. Bump and commit

Edit these lines:

- `CHANGELOG.md`: `## Unreleased` → `## X.Y.Z (YYYY-MM-DD)` (today's date)
- `mix.exs`: `@version "<old>"` → `@version "X.Y.Z"`
- On a minor bump only, the install snippets in `README.md` and
  `guides/phoenix-integration.md`: `{:enact, "~> <old>"}` →
  `{:enact, "~> X.Y.0"}`

Run what CI runs, then build the package to check its contents. The
tarball is gitignored.

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix hex.build
git commit -am "Release X.Y.Z"
```

**Checkpoint:** show the diff and test result, and give the remaining
commands. Don't push until asked.

## 4. Push and tag

Tags are lightweight, not annotated, and point at the release commit.
`mix.exs` links HexDocs source and the changelog to the tag, so push it
before the publish.

```sh
git push origin main
git tag vX.Y.Z
git push origin vX.Y.Z
```

**Checkpoint:** the maintainer runs `mix hex.publish` themselves, since it
needs their Hex credentials. Don't run it. Suggest `! mix hex.publish` and
wait for them to confirm it's published.

## 5. Create the GitHub release

The title is `Version X.Y.Z` and the body is the version's changelog
section without its heading. Write the notes to the scratchpad, not the repo.

```sh
awk '/^## X\.Y\.Z /{f=1;next} /^## /{f=0} f' CHANGELOG.md | sed '/./,$!d' > <scratchpad>/notes.md
cat <scratchpad>/notes.md
gh release create vX.Y.Z --title "Version X.Y.Z" --notes-file <scratchpad>/notes.md --latest
```

Finish by giving the release URL.
