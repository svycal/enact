# Changelog

## 0.1.0 (unreleased)

Initial release.

- `Enact.run/3` and `Enact.dry_run/3` — the `load → cast → authorize →
  validate → resolve → execute → after_commit` pipeline with actor
  enforcement, the closed error taxonomy, and telemetry events.
  Atom-keyed params are stringified at the boundary (values untouched;
  atom+string collision at the same level raises)
- `Enact.Action` and `Enact.InputSchema` behaviours; `Enact.Actor` protocol.
  `authorize/1` is required (an open write is a written `true`); optional
  callbacks are declared via `@optional_callbacks`
- Presence-based change detection: `Enact.provided?/2` and `Enact.updates/2`
- `Enact.Resolve` — scalar and batch reference resolution with
  enumeration-resistant error rendering
- `Enact.Validations` (`check/2`, `unique/3`) and `Enact.Guardrails`
  (mechanical input-schema invariants)
- `Enact.Preview` with a confirmation digest binding action, mode, and the
  canonical updates map
- `Enact.InputSchema.cast_input/4` — casting with JSON API empty-string
  semantics derived from field types (`keep_empty_strings:` option)
- `partial_embeds/1` input-schema manifest — partial-object PATCH
  semantics for declared `embeds_one` fields, with presence-faithful
  updates, previews, and confirmation digests
- `Enact.merged/4` — the result-state view of a partial embed,
  shared by merged-result validation rules and the execute-side merge
- `Enact.Test` helpers for host-app suites, including the
  `assert_rejects_empty_strings/3` behavioral probe
