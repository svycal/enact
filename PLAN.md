# Implementation plan

Working checklist for implementing `spec.md`. Each phase compiles clean and tests green before the next.

## Phase 0 — Scaffold ✅
- [x] `mix.exs` with `ecto` (not `ecto_sql`) + `telemetry` deps, hex package metadata, `0.1.0`
- [x] `.formatter.exs`, `test_helper.exs` (note: `consolidate_protocols: false` in test env so test files can define `Enact.Actor` impls)
- [x] Test support: fake repo (implements `transaction/1` + `rollback/1`, sends a message to the test process per transaction) — fixture input schemas/actions arrive with Phase 2

## Phase 1 — Leaf modules (data types & contracts) ✅
- [x] `Enact.Error` — struct + constructors (`invalid/1`, `forbidden/0-1`, `not_found/0-1`, `conflict/0-2`, `internal/1`) (§8)
- [x] `Enact.Context` — struct (§2.3)
- [x] `Enact.Actor` — protocol `anonymous?/1`, `@fallback_to_any` → false, `:anonymous` atom impl (§2.4)
- [x] `Enact.InputSchema` — behaviour (`changeset/3`, `fields/1`, optional `from_subject/1`) + canonical moduledoc on base semantics (§4.1)
- [x] `Enact.Action` — behaviour + `use` macro setting defaults only (§2.2)
- [x] Tests: constructors, actor protocol, `use Enact.Action` defaults

## Phase 2 — Runner core (`Enact`) ✅
- [x] `provided?/2` — key + path form, never raises, no atom conversion (§5.4)
- [x] `updates/2` — presence ∩ `fields(mode)`, `apply_changes` values (§5.2). Note: `fields/1` must include embed names (the §4.2 example elides this) or provided embeds could never reach updates
- [x] `run/3` pipeline: actor enforcement (nil raises; anonymous gate) → load → cast (base by mode, §5.1) → authorize → validate → execute in `repo.transaction/1` → after_commit (§3)
- [x] `input: nil` path: skip cast + validate, empty changeset, `updates/2` → `%{}` (§4)
- [x] Error normalization: load nil → `:not_found`; authorize false → `:forbidden`; invalid changeset → `:invalid`; constraint-error changeset from execute → promoted `:invalid`; `%Enact.Error{}` from execute/load/authorize passes through; other execute error → `:internal` (§3, §8)
- [x] Repo resolution: `repo:` opt → app config; `assigns:` passthrough (resolver keys win — merge lands with Phase 3)
- [x] Telemetry: `[:enact, :action, :success]` / `[:enact, :action, :error]` (§8)
- [x] Teaching raises: invalid `mode:` in config; patch-mode + input schema without a loaded subject
- [x] Tests: pipeline ordering invariants, both modes, error taxonomy mapping, provided?/updates edge cases (nil-clear, omitted, `[]`)
- Resolve step: seam exists between validate and persist; `Enact.Resolve` wiring is Phase 3

## Phase 3 — Resolution (`Enact.Resolve`) ✅
- [x] Scalar resolver: skip when no change; `:error` → generic "not found"; `{:error, msg}` → precise; stash struct in assigns (§7)
- [x] Batch/path resolver (one level deep): collect ids, single fetcher call, item-error splicing at correct indices, lookup map in assigns (§7)
- [x] Errors tagged `validation: :resolution`; collected without short-circuit; wired into runner between validate and execute
- [x] Teaching raises: path deeper than one level; resolver field missing from the input schema; malformed fetcher return
- [x] Tests: index-correct nested errors, dedup, nil ids skipped, no-change skip on patch, assigns shape (resolver keys win over passthrough)
- ~~Note (spec-inherent, §7 skip-on-no-change)~~ **Resolved in review**: scalar resolution is now presence-gated (`provided?` + `get_field`), not change-gated — a provided-identical reference on PATCH re-resolves, so `assigns[name]` is present whenever a non-nil reference appears in updates. §7's "skipped when no change" wording should be amended to "skipped when not provided / nil-cleared" (it contradicted §10.3's "provided reference re-resolves").

## Phase 4 — Validation helpers (`Enact.Validations`) ✅
- [x] `check/2` — no-op when changeset already invalid (§6)
- [x] `unique/3` — `scope:`, `repo:`, `query:` opts; skips when no change; errors tagged `validation: :unique` (§6). DB-backed, so callers wrap it in `check/2`; fake repo grew `exists?/2`
- [x] Tests

## Phase 5 — Guardrails (`Enact.Guardrails`) ✅
- [x] `assert_valid_input_schema!/2` — recursive walk with cycle guard: no scalar defaults, `@primary_key false` at all levels, no associations, top-level contract exports; `from_subject/1` required via `mode: :patch` opt (§9)
- [x] Memoized first-run check in the runner (`:persistent_term`, keyed per action; failures never memoize so they re-raise every run)
- [x] Tests: valid fixtures pass; default/PK (incl. nested)/association/missing-export fixtures raise with teaching messages; self-referential embed terminates; non-schema module raises (§10.5)

## Phase 6 — Dry run (`Enact.Preview` + digest) ✅
- [x] `Enact.Preview` struct; canonical digest encoding — every node type-tagged and maps sorted at every depth, then sha256 over `term_to_binary` (§12)
- [x] `dry_run/3` — shared `pre_execute` pipeline minus execute; distinct telemetry events (`[:enact, :action, :dry_run]` / `[..., :dry_run, :error]`)
- [x] `confirm_digest:` on `run/3` — recomputed post-validate/resolve, mismatch → `:conflict` with reason `:confirm_digest_mismatch`
- [x] `resolved:` carries resolver *names* (Resolve.run now returns them); structs never reach the preview
- [x] Tests: no writes on dry_run; preview updates == subsequent run's persisted updates; digest mismatch → `:conflict`; matching digest with changed world state still re-validates; preview never contains structs; digest determinism (large maps, dates, embed structs)

## Phase 7 — Test support (`Enact.Test`) + polish ✅
- [x] `assert_invalid/2` (`on:` option), `build_ctx/1`, `errors_on/1` shared for host apps (§10.8, §11); package tests now import `errors_on` from it
- [x] Moduledocs/docs pass (`mix docs` clean; spec.md shipped as a docs extra); README with quick-start; LICENSE (MIT); `mix hex.build` succeeds
- [x] Final line-count / surface review against §11 inventory (~1,240 lines incl. docs; heavier than the spec's 300–350 estimate, but the overage is moduledocs and teaching errors, not machinery)

**Status: all phases complete.** Remaining §10 items (doc-schema reconciliation, cross-tenant sweep, PATCH/create matrices against real schemas, projection completeness) are host-app tests by design (§11).

## Post-implementation review (fixed; 123 tests passing)

- **Guardrails missed `default: false`** — a bare `default = ...` binding in a `for` comprehension acts as a filter, silently skipping falsy defaults. Rewritten as `Enum.each`; regression test added.
- **Provided-identical PATCH reference skipped resolution** — scalar resolvers were change-gated; now presence-gated so the execute-side assigns contract is total (see Phase 3 note above). Spec §7 wording amendment recommended.
- **Path-form resolver on a scalar or `embeds_one` field crashed** with a bare `CaseClauseError`; now a teaching raise (`embeds_many` required). Same for a batch fetcher returning a non-map.
- **Digest hardened** — replaced `term_to_binary` with a hand-rolled injective byte encoding (type tags, length-prefixed binaries/atoms, entries sorted by encoded key) so digests survive mixed-OTP rolling deploys; cross-type collision tests added.
- **Spec's §1/§12 pipeline-order strings** said "cast → load"; corrected to match normative §3 ("load before cast").
- **Digest binds action + mode (implemented, spec §12 amended):** `Preview.digest/3` hashes `{action, mode, updates}` — a digest minted for one action or mode never confirms another, and `input: nil` actions no longer share one constant digest.
