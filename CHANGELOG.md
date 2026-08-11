# Changelog

## 0.1.0 (unreleased)

Initial release.

- `Enact.run/3` and `Enact.dry_run/3` — the `load → cast → authorize →
  validate → resolve → execute → after_commit` pipeline with actor
  enforcement, the closed error taxonomy, and telemetry events
- `Enact.Action` and `Enact.InputSchema` behaviours; `Enact.Actor` protocol
- Presence-based change detection: `Enact.provided?/2` and `Enact.updates/2`
- `Enact.Resolve` — scalar and batch reference resolution with
  enumeration-resistant error rendering
- `Enact.Validations` (`check/2`, `unique/3`) and `Enact.Guardrails`
  (mechanical input-schema invariants)
- `Enact.Preview` with a confirmation digest binding action, mode, and the
  canonical updates map
- `Enact.Test` helpers for host-app suites
