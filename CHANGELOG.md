# Changelog

## 0.1.0 (unreleased)

Initial release.

- `Enact.run/3`, `Enact.dry_run/3`, `Enact.subject/3`, and
  `Enact.authorized/3` — the
  `load → authorize → cast → validate → resolve → execute → after_commit`
  pipeline with actor enforcement, the closed error taxonomy, and
  telemetry events. `subject/3` returns the loaded record; `authorized/3`
  returns `:ok`. Both are load + authorize only (locator params, no body).
  Atom-keyed params are stringified at the boundary (values untouched;
  atom+string collision at the same level raises)
- `Enact.Action` and `Enact.InputSchema` behaviours; `Enact.Actor` protocol.
  `authorize/1` is required (an open write is a written `true`); optional
  callbacks are declared via `@optional_callbacks`
- Usage rules: params are the invocation payload; persistable fields are
  not passed via `assigns:`
- Phoenix guide: application callers use context one-liners that forward
  to `Enact.run/3` / `dry_run/3` / `subject/3` / `authorized/3`
- `Enact.Delegates` — opt-in `use` that generates those one-liners
  (`create_contact/2`, `create_contact_dry_run/2`,
  `create_contact_subject/2`, `create_contact_authorized/2`) from
  `actions: [CreateContact, ...]`
- Presence-based change detection: `Enact.provided?/2` and `Enact.updates/2`
- `Enact.Resolve` — scalar and batch reference resolution with
  enumeration-resistant error rendering
- `Enact.Validations` (`check/2`, `unique/3`) and `Enact.Guardrails`
  (mechanical input-schema invariants)
- `Enact.Preview` with a confirmation digest binding action, mode, locator
  params (params keys not in the input schema), and the canonical updates
  map; `subject` is the loaded record for old → new diffs
- `Enact.InputSchema.cast_input/4` — casting with JSON API empty-string
  semantics derived from field types (`keep_empty_strings:` option)
- `partial_embeds/1` input-schema manifest — partial-object PATCH
  semantics for declared `embeds_one` fields, with presence-faithful
  updates, previews, and confirmation digests
- `Enact.merged/4` — the result-state view of a partial embed,
  shared by merged-result validation rules and the execute-side merge
- `Enact.Test` helpers for host-app suites, including the
  `assert_rejects_empty_strings/3` behavioral probe
