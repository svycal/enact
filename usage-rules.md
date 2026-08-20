# Enact usage rules

Rules for writing application code in a project that uses Enact. Enact standardizes every write operation as an action module run through `load → cast → authorize → validate → resolve → execute → after_commit`. Enact orchestrates; Ecto does the work — there is no DSL and no custom validation vocabulary.

## Calling actions

- Every write goes through an action via `Enact.run/3`. Never write via `Repo.insert/update/delete`. Application callers (controllers, LiveViews, jobs) typically go through a context one-liner that only forwards to `Enact.run/3` / `dry_run/3` — see the Phoenix guide. Those one-liners may be handwritten or generated with `use Enact.Delegates, actions: [CreateProject, ...]`. Action tests and IEx may call `Enact.run/3` directly.
- Callers may pass atom- or string-keyed maps. The runner stringifies keys before any callback runs, so `load_subject/2` and `ctx.params` always see strings. Match `%{"id" => id}`, never `params[:id]`. Values are not rewritten.
- Params are the invocation payload, not "what a human typed." Jobs and `:system` are callers. A value this run is *saying* — something that will be persisted and previewed — belongs in params on an action whose `authorize/1` allows that caller.
- `actor:` is required and `actor: nil` raises. For unauthenticated callers pass an explicit anonymous actor (`:anonymous`, or a scope struct whose `Enact.Actor` impl returns `true`), and only against actions declaring `anonymous?: true` in `config/0`.
- Pass request metadata (IP, session id) via `assigns: %{}`. **Never** pass pre-loaded domain records or persistable fields through `assigns:` — records are fetched by `load_subject/2` / `resolvers/0`; persistable fields smuggled here skip cast, `updates/2`, preview, and the digest. Actions are self-contained; the extra query is the price.
- The same calling convention applies from controllers, background jobs, tests, and IEx. There is no internal-bypass path.
- For confirmation flows: the context's `*_dry_run` one-liner (or `Enact.dry_run/3`) returns an `%Enact.Preview{}`; pass `preview.digest` back as `confirm_digest:`. A mismatch returns `:conflict`. Compare `preview.updates` against `preview.subject` for old → new diffs. Resolved structs stay out of the preview (`resolved` is names only).

## Organizing modules

Group actions and inputs by context, in `actions/` and `inputs/` subdirectories, with module names mirroring paths:

```
lib/my_app/projects/
  projects.ex                 # context: reads, fetch helpers, write one-liners
  project.ex                  # persistence schema
  inputs/project_input.ex     # MyApp.Projects.Inputs.ProjectInput
  actions/create_project.ex   # MyApp.Projects.Actions.CreateProject
  actions/update_project.ex
  actions/archive_project.ex
```

- Input modules are shared per resource (one `ProjectInput` serving both create and patch), so they sit beside the actions that use them.
- The context module keeps reads, whatever `load_subject/2` delegates to, and one-liner write delegates (`def create_project(params, opts), do: Enact.run(CreateProject, params, opts)`, or `use Enact.Delegates, actions: [CreateProject]`). Those bodies only forward — no param reshaping, no persistable fields stamped in. The action is the write.
- Resolver fetchers start as private functions in the action that declares them; extract a shared module only at the second duplicated fetcher.
- Nested item schemas start nested inside their input module; promote to `inputs/<item>_input.ex` in the same context on second use.

## Writing an action

```elixir
defmodule MyApp.Projects.Actions.UpdateProject do
  use Enact.Action

  alias MyApp.Projects
  alias MyApp.Projects.Inputs.ProjectInput
  alias MyApp.Projects.Project

  @impl Enact.Action
  def config, do: [mode: :patch]

  @impl Enact.Action
  def input, do: ProjectInput

  @impl Enact.Action
  def load_subject(%{"id" => id}, ctx), do: Projects.get_project(ctx.actor, id)

  @impl Enact.Action
  def authorize(ctx), do: MyApp.Policy.can?(ctx.actor, :update, ctx.subject)

  @impl Enact.Action
  def execute(changeset, ctx) do
    updates = Enact.updates(changeset, ctx)

    ctx.subject
    |> Project.changeset(updates)
    |> ctx.repo.update()
  end
end
```

- `config/0`, `input/0`, and `resolvers/0` return **pure data**. `load_subject/2`, `authorize/1`, `validate/2`, `execute/2`, `after_commit/2` are **single-purpose functions**. Keep that dichotomy.
- `authorize/1` is required. Return `true`, `false`, or `{:error, reason}`. `false` becomes `{:error, %Enact.Error{type: :forbidden}}`; `{:error, :foo}` becomes `{:error, %Enact.Error{type: :forbidden, reason: :foo}}`. Use a host-owned atom for `reason` when the renderer should vary the 403 copy. Do not echo `reason` wholesale; do not put user-facing strings in it. An open write is a written `true` (`def authorize(_ctx), do: true`), never an omitted callback.
- The URL-anchored record is the **subject** → override `load_subject/2` (the updated record in patch mode; the parent in create-under-parent). The default is a no-op (`:no_subject`); `nil` means `:not_found`. Body-referenced public ids → `resolvers/0`. No other fetching channel.
- `load_subject/2` and every resolver fetcher **must scope by a trust anchor**: the actor's tenant when authenticated; a public-by-construction subject for `anonymous?: true` actions. Returning `nil` from `load_subject/2` produces `:not_found` — cross-tenant probes must be indistinguishable from nonexistent records.
- Never invent error atoms. The taxonomy is closed: `:invalid`, `:forbidden`, `:not_found`, `:conflict`, `:internal`. To signal a race from `execute/2`, return `{:error, Enact.Error.conflict(:reason)}`.
- In `execute/2`: build the write from `Enact.updates(changeset, ctx)` — **never** from bare `apply_changes/1` (it erases omitted-vs-provided). Translate public ids by reading `ctx.assigns` (e.g. `ctx.assigns.owner.id`). The updates map is persistence-ready: embeds arrive as plain maps, so feed it straight to your persistence changeset. Declare DB constraints; the runner promotes constraint-error changesets to `:invalid`.
- Values the action decides (tenant, parent id, default permissions) are stamped in `execute/2` from `ctx.actor`, `ctx.subject`, or policy — not passed in. Do not give one field two sources (params for users, assigns for the system). Split the action or the input module when the payloads differ.
- `after_commit/2` is for post-commit side effects only (job insertion, analytics). It runs outside the transaction and can never roll back.
- Archive/cancel/resend-style actions: `mode: :patch, input: nil` plus an overridden `load_subject/2` — preconditions go in `authorize/1`, subject checks in `load_subject/2`.

## Input schemas

- An input module is a plain `use Ecto.Schema` + `embedded_schema` module that adds `use Enact.InputSchema` (sets the behaviour and imports `cast_input/4` — nothing more), implementing `changeset/3` (one head per mode), `fields/1`, and — iff any patch-mode action uses it — `from_subject/1`.
- Cast scalar fields with `cast_input/4`, not stock `cast`: it derives empty-string handling from field types — `""` on a non-string field is a cast error instead of a silently-coerced `nil`; empty-ish `:string` values (`""`, whitespace-only) coalesce to `nil`, and non-empty values pass through as sent (casting never modifies values — trimming is an explicit changeset-head concern if wanted). One option: `keep_empty_strings:` for `NOT NULL DEFAULT ''` columns. Cast embeds with `cast_embed/3` as usual.
- `@primary_key false` at **every** nesting level. No `default:` on any field. No associations — embeds only. (`Enact.Guardrails` raises on all three at first run.)
- Required-ness lives in the changeset heads via `validate_required`, never in the schema. Per-mode differences are expressed as data (cast lists, required lists) — if you need conditionals inside the changeset heads, split into separate input modules.
- `fields/1` must list the mode's castable fields **including embed names** — `Enact.updates/2` and the host test suite read it.
- Nested item schemas implement Ecto's native `changeset/2` (invoked by `cast_embed`) and do **not** adopt the behaviour — take the bare `import Enact.InputSchema` and still cast with `cast_input/4`. This asymmetry is deliberate. Note the strictness probe covers top-level fields only (item schemas have no `fields/1` manifest), so item-level strictness is a convention, not a probed guarantee.
- Embeds are replace-wholesale by default. Declare `embeds_one` fields that accept partial objects in the optional `partial_embeds/1` manifest — `Enact.updates/2` then carries only the provided sub-keys, and `execute/2` merges over the subject via `Enact.merged/4` (the same function merged-result validations use). `embeds_many` cannot be partial. Worked example: recipe 6.
- `from_subject/1` is an explicit projection of the subject into the input vocabulary (public-id rendering, renames), total over scalar fields. Never seed embeds — leave them at structural defaults. Never implement it as a blind `Map.take`.
- Pair with the data-layer convention: optional scalar columns are **nullable with no default** — `NULL` is the single representation of empty, so empty strings coalescing to `nil` is correct and an explicit `null` is just a clear. Reserve `NOT NULL DEFAULT ''` for fields where `""` is genuinely meaningful as distinct from absent; list those in `cast_input/4`'s `keep_empty_strings:` — see the Change Detection guide.

## Validation

- Payload-intrinsic rules (format, bounds, inclusion) → the input module's own pipeline. Operation- and actor-aware rules → the action's `validate/2`. Dividing line: "true of this data anywhere" vs. "true in this operation."
- Read result-state with `get_field/2` — the patch base guarantees it returns the value the record will have. **Forbidden:** `get_change(cs, :field) || ctx.subject.field`.
- Wrap every DB-backed check in `Enact.Validations.check/2` (no-ops when the changeset is already invalid). Use `Enact.Validations.unique/3` for scoped uniqueness pre-flight. On PATCH pass `except: ctx.subject`. Filter soft-deletes on `:query`.
- Gate rules that must run only when the caller touched a key — including `[]`-clears, which `get_change`-gating would miss — with `Enact.provided?(ctx, key_or_path)`. That is the only sanctioned raw-params read in a validation.
- For rules about the merged result of a partial embed, build the result-state view with `Enact.merged(changeset, ctx, :embed)` — each sub-key reads the caller's value where provided (explicit nulls read as clears) and the subject's current value where not.

## PATCH semantics

Omitted key → untouched. Explicit `null` → clears the scalar. Array key present → replaces wholesale; `[]` clears (arrays never clear with `null`). `Enact.updates/2` implements all of this via presence-in-params — trust it rather than hand-rolling merge logic in `execute/2`. (Mechanics explained in the Change Detection guide, `guides/change-detection.md`.)

## Resolvers

- Scalar: `name: {:field, fetcher}` where `fetcher.(public_id, ctx)` returns `{:ok, struct} | :error | {:error, message}`. Batch over an `embeds_many`: `name: {[:embed, :item_field], fetcher}` where `fetcher.(ids, ctx)` returns `%{public_id => struct | {:error, message}}`.
- **Trust-anchor rule:** scope the query by the trust anchor first. Missing and wrong-tenant must both produce the generic `:error` → `"not found"`. Precise messages (`{:error, "has been deactivated"}`) are permitted only for records the anchor-scoped query returned.
- Every `*_id` payload field gets a resolver entry (or an explicit allowlist entry in the host coverage test). Forgetting one sends a raw public-id string to persistence.
- Resolution failures render as field-level `:invalid` errors, never `:not_found`.

## Errors

- One renderer handles the closed taxonomy; it must never need a default clause for `type`. Default copy is generic by type. You may match host-owned `reason` atoms (usually `:forbidden`) to vary the message; do not echo `reason` wholesale. The only type that carries caller-visible detail by default is `:invalid` via the changeset.

## Testing

- `import Enact.Test` for `assert_invalid/2`, `build_ctx/1`, `errors_on/1`.
- Host apps own the tests that depend on their actions, schemas, and tenancy: guardrails-in-CI, the cross-tenant sweep, the PATCH/create matrices, projection completeness, and resolver coverage. See the "Testing Host Applications" guide for templates.

## Worked examples

End-to-end samples following these conventions — embedded data with batch resolution, flattening embeds into columns, reading resolver assigns in execute, MCP dry-run confirmation flows, empty-string-at-rest columns, partial updates on singular embeds — live in the Recipes guide (`guides/recipes.md`).
