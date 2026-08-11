# Enact usage rules

Rules for writing application code in a project that uses Enact. Enact standardizes every write operation as an action module run through `load → cast → authorize → validate → resolve → execute → after_commit`. Enact orchestrates; Ecto does the work — there is no DSL and no custom validation vocabulary.

## Calling actions

- Every write goes through `Enact.run(ActionModule, params, actor: actor)`. Never write via `Repo.insert/update/delete` from context functions — actions are the only write path.
- `actor:` is required and `actor: nil` raises. For unauthenticated callers pass an explicit anonymous actor (`:anonymous`, or a scope struct whose `Enact.Actor` impl returns `true`), and only against actions declaring `anonymous?: true` in `config/0`.
- Pass request metadata (IP, session id) via `assigns: %{}`. **Never** pass pre-loaded domain records through `assigns:` — the subject is fetched by `load/2`, payload references by `resolvers/0`. Actions are self-contained; the extra query is the price.
- The same calling convention applies from controllers, background jobs, tests, and IEx. There is no internal-bypass path.
- For confirmation flows: `Enact.dry_run/3` returns an `%Enact.Preview{}`; pass `preview.digest` back to `run/3` as `confirm_digest:`. A mismatch returns `:conflict`.

## Organizing modules

Group actions and inputs by context, in `actions/` and `inputs/` subdirectories, with module names mirroring paths:

```
lib/my_app/projects/
  projects.ex                 # context: reads + fetch helpers (no writes)
  project.ex                  # persistence schema
  inputs/project_input.ex     # MyApp.Projects.Inputs.ProjectInput
  actions/create_project.ex   # MyApp.Projects.Actions.CreateProject
  actions/update_project.ex
  actions/archive_project.ex
```

- Input modules are shared per resource (one `ProjectInput` serving both create and patch), so they sit beside the actions that use them.
- The context module keeps reads and whatever `load/2` delegates to — never writes; writes go through `Enact.run`.
- Resolver fetchers start as private functions in the action that declares them; extract a shared module only at the second duplicated fetcher.
- Nested item schemas start nested inside their input module; promote to `inputs/<item>_input.ex` in the same context on second use.

## Writing an action

```elixir
defmodule MyApp.Projects.Actions.UpdateProject do
  use Enact.Action

  @impl Enact.Action
  def config, do: [mode: :patch, loads_subject?: true]

  @impl Enact.Action
  def input, do: MyApp.Projects.Inputs.ProjectInput

  @impl Enact.Action
  def load(%{"id" => id}, ctx), do: MyApp.Projects.get_project(ctx.actor, id)

  @impl Enact.Action
  def authorize(ctx), do: MyApp.Policy.can?(ctx.actor, :update, ctx.subject)

  @impl Enact.Action
  def execute(changeset, ctx) do
    updates = Enact.updates(changeset, ctx)
    ctx.subject |> MyApp.Project.changeset(updates) |> ctx.repo.update()
  end
end
```

- `config/0`, `input/0`, and `resolvers/0` return **pure data**. `load/2`, `authorize/1`, `validate/2`, `execute/2`, `after_commit/2` are **single-purpose functions**. Keep that dichotomy.
- The URL-anchored record is the **subject** → fetch it in `load/2` (the updated record in patch mode; the parent in create-under-parent). Body-referenced public ids → `resolvers/0`. No other fetching channel.
- `load/2` and every resolver fetcher **must scope by a trust anchor**: the actor's tenant when authenticated; a public-by-construction subject for `anonymous?: true` actions. Returning `nil` from `load/2` produces `:not_found` — cross-tenant probes must be indistinguishable from nonexistent records.
- Never invent error atoms. The taxonomy is closed: `:invalid`, `:forbidden`, `:not_found`, `:conflict`, `:internal`. To signal a race from `execute/2`, return `{:error, Enact.Error.conflict(:reason)}`.
- In `execute/2`: build the write from `Enact.updates(changeset, ctx)` — **never** from bare `apply_changes/1` (it erases omitted-vs-provided). Translate public ids by reading `ctx.assigns` (e.g. `ctx.assigns.owner.id`). Convert embed structs to plain maps before feeding a persistence changeset (`Ecto.Changeset.cast` raises on struct params). Declare DB constraints; the runner promotes constraint-error changesets to `:invalid`.
- `after_commit/2` is for post-commit side effects only (job insertion, analytics). It runs outside the transaction and can never roll back.
- Archive/cancel/resend-style actions: `mode: :patch, loads_subject?: true, input: nil` — preconditions go in `authorize/1`, subject checks in `load/2`.

## Input schemas

- An input module is a plain `use Ecto.Schema` + `embedded_schema` module declaring `@behaviour Enact.InputSchema`, implementing `changeset/3` (one head per mode), `fields/1`, and — iff any patch-mode action uses it — `from_subject/1`.
- `@primary_key false` at **every** nesting level. No `default:` on any field. No associations — embeds only. (`Enact.Guardrails` raises on all three at first run.)
- Required-ness lives in the changeset heads via `validate_required`, never in the schema. Per-mode differences are expressed as data (cast lists, required lists) — if you need conditionals inside the changeset heads, split into separate input modules.
- `fields/1` must list the mode's castable fields **including embed names** — `Enact.updates/2` and the host test suite read it.
- Nested item schemas implement Ecto's native `changeset/2` (invoked by `cast_embed`) and do **not** declare the behaviour. This asymmetry is deliberate.
- `from_subject/1` is an explicit projection of the subject into the input vocabulary (public-id rendering, renames), total over scalar fields. Never seed embeds — leave them at structural defaults. Never implement it as a blind `Map.take`.

## Validation

- Payload-intrinsic rules (format, bounds, inclusion) → the input module's own pipeline. Operation- and actor-aware rules → the action's `validate/2`. Dividing line: "true of this data anywhere" vs. "true in this operation."
- Read result-state with `get_field/2` — the patch base guarantees it returns the value the record will have. **Forbidden:** `get_change(cs, :field) || ctx.subject.field`.
- Wrap every DB-backed check in `Enact.Validations.check/2` (no-ops when the changeset is already invalid). Use `Enact.Validations.unique/3` for scoped uniqueness pre-flight.
- Gate rules that must run only when the caller touched a key — including `[]`-clears, which `get_change`-gating would miss — with `Enact.provided?(ctx, key_or_path)`. That is the only sanctioned raw-params read in a validation.

## PATCH semantics

Omitted key → untouched. Explicit `null` → clears the scalar. Array key present → replaces wholesale; `[]` clears (arrays never clear with `null`). `Enact.updates/2` implements all of this via presence-in-params — trust it rather than hand-rolling merge logic in `execute/2`.

## Resolvers

- Scalar: `name: {:field, fetcher}` where `fetcher.(public_id, ctx)` returns `{:ok, struct} | :error | {:error, message}`. Batch over an `embeds_many`: `name: {[:embed, :item_field], fetcher}` where `fetcher.(ids, ctx)` returns `%{public_id => struct | {:error, message}}`.
- **Trust-anchor rule:** scope the query by the trust anchor first. Missing and wrong-tenant must both produce the generic `:error` → `"not found"`. Precise messages (`{:error, "has been deactivated"}`) are permitted only for records the anchor-scoped query returned.
- Every `*_id` payload field gets a resolver entry (or an explicit allowlist entry in the host coverage test). Forgetting one sends a raw public-id string to persistence.
- Resolution failures render as field-level `:invalid` errors, never `:not_found`.

## Errors

- One renderer handles the closed taxonomy; it must never need a default clause. `Enact.Error.reason` is internal-only (logs/telemetry) — never serialize it. The only outward-rich type is `:invalid` via the changeset.

## Testing

- `import Enact.Test` for `assert_invalid/2`, `build_ctx/1`, `errors_on/1`.
- Host apps own five test obligations per the design spec: guardrails-in-CI, the cross-tenant sweep, the PATCH/create matrices, projection completeness, and resolver coverage. See the "Testing Host Applications" guide for templates.
