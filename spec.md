# Enact — Design Specification

A thin, behaviour-based action layer for application write operations, published as a Hex package for use across multiple host applications. This document is the authoritative design; it captures decisions and their rationale so implementation does not relitigate them.

## 1. Purpose and philosophy

Enact standardizes the shape of every write operation: load → cast → authorize → validate → resolve → execute → after-commit. It is **Plug for writes** — the value is the uniform pipeline shape, the actor context, and the error taxonomy, not any novel validation or persistence machinery.

**Enact orchestrates; Ecto does the work.** Validation is Ecto changesets. Input casting is Ecto embedded schemas. Persistence is the host application's existing Ecto schemas and changesets. Enact adds no parallel type system, no validation vocabulary, and no DSL.

Target size: roughly 300–350 lines total (runner, Context, Error, Preview, Resolve, Validations helpers, Guardrails).

### Non-goals (decided, do not revisit during implementation)

- **No DSL / no macro code generation.** The only macro is `use Enact.Action`, which sets `@behaviour` and default callback implementations. Nothing else. Rationale: debuggability, greppability, AI-coding-agent navigability, and reversibility — a DSL frontend can be layered on later as optional sugar; the reverse migration is much harder.
- **No custom changeset or validation library.** `Ecto.Changeset` is the one and only changeset. `Enact.Validations` contains a small number of helpers that _compose into_ Ecto pipelines, never replacements for `validate_*` functions.
- **No third-party validation dependency** (Peri, Drops, etc.). Revisit only if a census of real actions shows nested input is pervasive enough that per-shape input modules become a tax paid everywhere.
- **No OpenAPI generation from input schemas, and no knowledge of any API-documentation library** (OpenApiSpex included). The package exposes introspection manifests (`fields/1`, `resolvers/0`); host apps hand-write their doc schemas (the public contract should change only by deliberate act) and prevent drift with a host-side reconciliation test against those manifests (§10), not codegen.
- **No raising variant (`run!`)**, no code-interface sugar (`define :create_project`), no imperative `resolve/2` escape hatch. All deferred under the second-use rule: introduce only when a real caller demonstrates need.

## 2. Public API

### 2.1 Caller contract

```elixir
# required: actor
Enact.run(ActionModule, params, actor: actor)
# repo override (tests; default from app config)
Enact.run(ActionModule, params, actor: actor, repo: R)

Enact.run(ActionModule, params,
  actor: actor,
  # optional — see §12 (dry-run confirmation)
  confirm_digest: digest
)

# Returns:
{:ok, result}
{:error, %Enact.Error{type: :invalid | :forbidden | :not_found | :conflict | :internal}}

# same options as run/3, minus confirm_digest
Enact.dry_run(ActionModule, params, actor: actor)
# Returns: {:ok, %Enact.Preview{}} | {:error, %Enact.Error{}}   — see §12
```

- The actor is always an explicit, required option. No ambient/process-dictionary context. Every write path is greppable via `Enact.run` and must answer "as whom?" — actorless writes are unrepresentable by construction (valuable for audit/compliance posture).
- **`actor: nil` always raises `ArgumentError`** (message points at anonymous actors, §2.4): nil is indistinguishable from a forgotten actor — anonymity must be a pattern-matchable value, never an absence. The deliberate collision with Phoenix's `current_scope: nil` forces public-endpoint callers to construct an explicit anonymous actor at the boundary.
- The actor is **opaque to Enact** — only the host app's `authorize/1` and fetchers read it. Any term works, with no Phoenix dependency; in Phoenix 1.8+ apps the recommended actor is the scope struct (`actor: conn.assigns.current_scope`), whose role Enact actions naturally inherit.
- `run/3` and `dry_run/3` accept an optional `assigns: %{}` passthrough merged into `ctx.assigns` — the documented channel for request metadata (IP, session id) that isn't part of the actor. Resolver-stashed keys are merged after and win on collision.
- Callers never choose the mode; mode is the action's identity via `config/0`.
- Same calling convention from controllers, background jobs, tests, IEx. No internal-bypass path.

### 2.2 The behaviour

Every callback is either **pure data** or **a single-purpose function over (changeset | params, ctx)**. Maintain this dichotomy.

| Callback         | Required              | Kind     | Purpose                                                                                                                                                                                                   |
| ---------------- | --------------------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `config/0`       | no (default `[]`)     | data     | `mode: :create \| :patch` (default `:create`), `loads_subject?: boolean` (default `false`), `anonymous?: boolean` (default `false`, §2.4)                                                                 |
| `input/0`        | yes                   | data     | Input-schema module, or `nil` for input-less actions (§4)                                                                                                                                                 |
| `load/2`         | no (default `nil`)    | function | Fetch the subject — the URL-anchored record the action operates on _or within_ (the updated record in patch mode; the parent in create-under-parent); `(params, ctx) → struct \| nil \| {:error, reason}` |
| `authorize/1`    | no (default `true`)   | function | `(ctx) → boolean \| {:error, reason}`                                                                                                                                                                     |
| `validate/2`     | no (default identity) | function | Ordinary changeset pipeline; `(changeset, ctx) → changeset`. Not invoked for `input: nil` actions                                                                                                         |
| `resolvers/0`    | no (default `[]`)     | data     | Reference-resolution spec (§7)                                                                                                                                                                            |
| `execute/2`      | yes                   | function | Persist; `(changeset, ctx) → {:ok, term} \| {:error, term}`; runs in transaction                                                                                                                          |
| `after_commit/2` | no (default `:ok`)    | function | Post-commit side effects (job insertion, analytics); never rolls back                                                                                                                                     |

`use Enact.Action` sets `@behaviour Enact.Action` and `defoverridable` defaults for the optional callbacks. That is its entire body.

### 2.3 Context

```elixir
%Enact.Context{
  # required, from opts; opaque (struct, scope, or :anonymous)
  actor: term(),
  # filled by load step: updated record (patch) or parent anchor (create)
  subject: struct() | nil,
  # raw params — kept for presence checks & audit
  params: map(),
  repo: module(),
  # from action config
  mode: :create | :patch,
  # resolve step stashes loaded references here
  assigns: %{}
}
```

### 2.4 Actors, scopes, and anonymity

Some actions must accept unauthenticated callers (e.g. a public visitor creating a booking through a public link). Design:

- **Anonymity is a declared property of the action**: `config/0` returns `anonymous?: true`. The security-review question "which write paths accept unauthenticated callers?" is answered by grepping for it — a closed, auditable list, parallel to `loads_subject?`. An authenticated actor may still call an anonymous-capable action (`anonymous?` is a floor, not a partition).
- **The `Enact.Actor` protocol** answers `anonymous?/1` for any actor term: `@fallback_to_any` returns `false`; a built-in impl makes the bare `:anonymous` atom anonymous (zero-ceremony option for simple apps); host apps add a small impl for their scope struct (`%Scope{user: nil} → true`), enabling rich anonymous scopes carrying session id / IP for rate limiting — the idiomatic Phoenix 1.8 shape.
- **Runner enforcement**: `actor: nil` raises (always, §2.1). `Enact.Actor.anonymous?(actor)` true → permitted only when the action declares `anonymous?: true`, otherwise `{:error, %Enact.Error{type: :forbidden}}` before any pipeline work. Applies identically to `dry_run/3`.
- **Tenancy anchoring without an actor**: convention #1 (§9) generalizes — every load and fetcher scopes by a _trust anchor_: the actor when authenticated, a public-by-construction subject when anonymous (e.g. `load/2` fetches the resource by public slug + visibility flag, and all fetchers scope through `ctx.subject`'s tenant, not the actor). Anonymous endpoints are the prime ID-enumeration surface; §7's "not found ≡ not yours" property does real work here.
- **Audit/telemetry**: events record the anonymous actor affirmatively ("an unauthenticated party did X"), never a null field.

## 3. Pipeline

**Full pipeline:** `load → cast → authorize → validate → resolve → execute → after_commit`

The `load` step runs first whenever `loads_subject?: true`, in either mode (rationale in invariant 3); actions without a subject skip it.

Ordering invariants (structural, not conventional):

1. **Authorize before validate** — unauthorized callers learn nothing about what's invalid.
2. **Validate before resolve** — cheap gates expensive; garbage input never triggers reference loads.
3. **Load before cast** — in patch mode the subject supplies the validation base via `from_subject/1` (§5.3); in create mode load-first is harmless and keeps the pipeline uniform.
4. **Execute inside `repo.transaction/1`**; `{:error, reason}` from execute rolls back. `after_commit` runs strictly after successful commit, outside the transaction.

Runner error normalization:

- No cast-stage fast-fail: `changeset/3` output (cast, required-ness, base validations) flows into `validate/2`, and one `:invalid` is produced after the validate step, in both modes — the caller gets all input errors in a single response. (The runner cannot distinguish cast errors from module validations anyway; `check/2` gates the expensive checks.)
- `load/2` returning nil (when `loads_subject?: true`) → `:not_found`.
- `authorize/1` false → `:forbidden`.
- Post-validate `changeset.valid? == false` → `:invalid` carrying the changeset.
- A `%Ecto.Changeset{}` error from `repo.insert/update` (declared constraints) → promoted to `:invalid`, not `:internal`.
- Any other execute failure → `:internal` (see §8 discipline).

**Where record-fetching lives:** URL-anchored records → `load/2` (the subject); body-referenced records → `resolvers/0` (§7). Do **not** pass pre-loaded domain records via the `assigns:` passthrough: an externally-loaded record escapes trust-anchor enforcement, breaks `run`/`dry_run` parity for callers with no controller (jobs, MCP), and makes provenance unauditable. Actions are self-contained — the extra query is the price, and it's cheap.

## 4. Input schemas

`input/0` returns an **embedded-schema input module**, or **`nil`** for input-less actions.

There is exactly one input shape — do not add others during implementation. Rejected alternatives, and why:

- **Flat schemaless types maps** (`%{name: {:string, required: true}}`): the `{type, required: true}` tuple is an Enact-invented schema vocabulary; modules-only keeps "input schemas are just Ecto" literally true. A dual shape forces a second code path through every subtle part of the runner (cast, base construction, `updates/2` key selection, guardrails, reconciliation) — precisely where the PATCH edge cases live — and requires a special runner-applied `validate_required` rule, whereas with modules required-ness lives in the changeset heads like everything else. The saving is ~8 lines per action, amortized away by shared input modules.
- **Inline nested-map recursion in the runner** (nested schemas as literal maps, cast recursively): forces manual `valid?` propagation and `changes`-internals knowledge into application code; `cast_embed` on embedded-schema modules does both natively.

**`input/0 → nil`** (archive, cancel, resend — subject in the URL, empty body): the runner skips cast **and** validate, passing an empty changeset through the pipeline; an input-less action's preconditions belong in `authorize/1` and its subject checks in `load/2`. `updates/2` returns `%{}`. Typical config for archive/cancel-style actions: `mode: :patch, loads_subject?: true, input: nil`.

### 4.1 Input module contract — `Enact.InputSchema`

With modules as the only input shape, the module's interface is the library's second behavioural contract (after `Enact.Action`) and is formalized as one:

```elixir
defmodule Enact.InputSchema do
  @callback changeset(base :: struct(), params :: map(), mode :: atom()) :: Ecto.Changeset.t()
  @callback fields(mode :: atom()) :: [atom()]
  @callback from_subject(subject :: struct()) :: struct()

  # required iff a patch-mode action uses the module
  @optional_callbacks from_subject: 1
end
```

- **`use Enact.InputSchema`** adopts the contract: it sets `@behaviour Enact.InputSchema` (compile-time signature warnings, dialyzer coverage) and imports `cast_input/4` — exactly that, never more. `use Ecto.Schema`, `import Ecto.Changeset`, and `@primary_key false` stay explicit. The general rule: Enact's two behaviours are adopted via `use`, and each `use` sets the behaviour and exposes that module's own functions, nothing else. Plain `@behaviour` + `import` remains equivalent — guardrails and tests check exports, not the adoption mechanism. The behaviour module's moduledoc is the canonical home for base semantics (why the base exists, what `from_subject/1` must guarantee, why no defaults).
- **Mode provenance:** the runner passes `config[:mode]` verbatim as the third argument. The union is closed to `:create | :patch` (matching `Context.mode` and the `config/0` docs). A future custom mode (§13) is mostly an additional `changeset/3` head, plus a declaration (e.g. via config) of whether it bases like create (empty struct) or patch (`from_subject/1`) for the runner's §5.1 branch.
- **`fields/1` is part of the contract**, not just test sugar: it is the introspection surface for mode-specific castable fields (`__schema__(:fields)` cannot distinguish create-castable from patch-castable). `updates/2` key selection (§5.2) and the reconciliation and resolver-coverage tests (§10) read it.
- **`partial_embeds/1`** (optional, default `[]`) declares `embeds_one` fields with partial-object semantics: `updates/2` filters their sub-keys by presence (§5.2), so updates, previews, and confirmation digests carry exactly the provided sub-keys, and `execute/2` merges over the subject via `Enact.merged/4`. `embeds_many` cannot be declared partial (array merging requires item identity — a different contract); guardrail-enforced. A seeded `on_replace: :update` alternative was evaluated and deferred (§13).
- **`from_subject/1` builds the patch-mode validation base** (§5.3): an explicit, total projection of the subject into the input representation. Required whenever a patch-mode action uses the module; create-only modules may omit it.
- **Enforcement** is belt-and-suspenders: the behaviour annotation warns at compile time; the guardrails walk (§9) hard-checks `function_exported?(module, :changeset, 3)` and `fields/1` at first run / in CI, with teaching errors, for modules that skip the annotation.
- **`cast_input/4`** (a function on the behaviour module, imported by input modules) is the casting entry for scalar fields: stock `cast` plus JSON-API empty-string semantics derived from field types. `""` on a non-string field is a cast error rather than a silently-coerced `nil` (Ecto's forms-era default); empty-ish `:string` values (`""`, whitespace-only — the trimmed emptiness test matches Ecto's own default) coalesce to `nil`, with `keep_empty_strings:` keeping `""` as the value for empty-string-at-rest columns. Casting interprets input and never modifies values — non-empty strings pass through as sent; trimming/hygiene is an explicit changeset-head concern. The option set is closed; required-ness, embeds, defaults, and null-rejection stay where they otherwise live. Stock `cast` remains legal — `Enact.Test.assert_rejects_empty_strings/3` behaviorally verifies the empty-string outcome regardless of mechanism (probing is safe because input modules are dependency-free by contract).
- **Deliberate asymmetry — nested item schemas use `changeset/2`.** Items (`Milestone` etc.) are invoked by `cast_embed`, not the runner, and are mode-blind: the parent's mode-specific cast list decides whether the embed is reachable at all. Item schemas follow Ecto's native `cast_embed` convention; top-level input modules follow Enact's `/3`. Do not "fix" this into a uniform arity. Item schemas take the bare `import Enact.InputSchema` (no `use` — they don't adopt the behaviour) and still cast with `cast_input/4`; since items have no `fields/1` manifest, item-level empty-string strictness is a convention rather than a probed guarantee. If an item schema is later promoted to a top-level input for some action (e.g. an "add one item" endpoint), it gains a `changeset/3` alongside its `changeset/2` — same module, both contracts, no conflict.

### 4.2 Shared create/patch input modules

Field definitions are written once; per-mode deltas are expressed as data (cast lists / required lists). Convention (illustrative example — a `Project` resource with nested milestones):

```elixir
defmodule MyApp.Projects.Inputs.ProjectInput do
  use Ecto.Schema
  # sets @behaviour and imports cast_input (§4.1)
  use Enact.InputSchema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :name, :string
    field :slug, :string
    # NO defaults — guardrail-enforced
    field :priority, :integer
    # public-facing ID; resolved later
    field :owner_id, :string
    # __MODULE__-qualified: the nested module is defined below, and a bare
    # alias would resolve before its defmodule registers it
    embeds_many :milestones, __MODULE__.Milestone
  end

  @all ~w(name slug priority owner_id)a
  # e.g. slug immutable after create
  @patch @all -- [:slug]
  @required ~w(name slug)a

  # one annotation covers both heads
  @impl true
  def changeset(base, params, :create) do
    base
    |> cast_input(params, @all)
    |> validate_required(@required)
    |> cast_embed(:milestones, required: true)
    |> base_validations()
  end

  def changeset(base, params, :patch) do
    # base makes this correct on PATCH (§5.3)
    base
    |> cast_input(params, @patch)
    |> validate_required(@required)
    |> cast_embed(:milestones)
    |> base_validations()
  end

  @impl true
  def fields(:create), do: @all
  def fields(:patch), do: @patch

  @impl true
  # subject → input vocabulary; embeds never seeded (§5.3)
  def from_subject(project) do
    %__MODULE__{
      name: project.name,
      slug: project.slug,
      priority: project.priority,
      owner_id: PublicIds.encode(:user, project.owner_id)
    }
  end

  # format/bounds/inclusion rules (elided)
  defp base_validations(cs), do: cs

  defmodule Milestone do
    use Ecto.Schema
    import Ecto.Changeset
    # NOTE: bare import, not `use` — item schemas are changeset/2, invoked
    # by cast_embed, and exempt from the InputSchema contract (§4.1
    # asymmetry); they still cast with cast_input for empty-string strictness
    import Enact.InputSchema, only: [cast_input: 3]

    @primary_key false
    embedded_schema do
      field :title, :string
      field :due_on, :date
      field :owner_id, :string
    end

    def changeset(item, params) do
      item
      |> cast_input(params, [:title, :due_on, :owner_id])
      |> validate_required([:title])
    end
  end
end
```

- The runner calls `module.changeset(base, params, ctx.mode)`.
- `base_validations/1` holds rules **intrinsic to the payload** (format, bounds, inclusion). Action/actor-aware rules stay in the action's `validate/2`. Dividing line: "true of this data anywhere" vs. "true in this operation." Input modules take no ctx/repo — keep them dependency-free.
- Per-item validations for embeds live in the item schema's own `changeset/2`; `cast_embed` invokes them and handles error nesting and `valid?` propagation natively.
- Nested item modules start nested inside the input module; promote to the context's `Inputs` namespace on second use. Actions and inputs organize by context (`MyApp.Projects.Actions.CreateProject`, `MyApp.Projects.Inputs.ProjectInput`), module names mirroring paths.
- **When to split rather than share:** if expressing the create/patch delta requires conditionals inside the changeset functions (beyond required-ness and cast lists), the payloads aren't really the same — write separate input modules.
- Escalation for a third variant (admin, API-version): additional changeset head + fields list; mode atom may come from `config/0`. Do not pre-build.

### 4.3 Input schema invariants (mechanically enforced — see §9)

1. **No `default:` on any field.** Omitted fields are excluded from extraction by presence (§5.2), so a schema default never persists — it would only mislead validations into seeing a value the write will not contain. Defaults live in exactly one place: the DB column (preferred) or persistence schema. The host app's API docs document them; the database applies them.
2. **`@primary_key false`, recursively.** Item IDs cause `cast_embed` to switch to diff-by-id semantics, silently breaking replace-wholesale PATCH arrays.
3. **No associations** (`has_many`/`belongs_to`) — embeds only. An association in an input module means the input/persistence boundary is being blurred.

## 5. Change detection and the validation base

PATCH requirements: omitted key → untouched; explicit `null` → clears a scalar field; array key present → replace wholesale (arrays clear with `[]`, never `null` — `cast_embed` rejects null on `embeds_many`, so the contract self-enforces).

Two distinct questions run through every write, and each has exactly one answering mechanism. Keeping them separate is the section's central rule:

- **"What did the caller say?"** → answered by **presence in raw params**. Drives extraction/persistence (§5.2).
- **"What is the world?"** → answered by the **validation base** (§5.3). Drives what validations see. Never drives extraction.

One mechanism must never answer the other's question: extraction that depends on a diff against the base couples persisted data to base correctness; validations that consult raw params for values re-do casting by hand.

### 5.1 Casting and the base, by mode

The runner builds the base struct, then calls `changeset(base, params, mode)`:

- **Create:** base = empty struct (`%Input{}`). Everything provided casts as a change.
- **Patch:** base = `input_module.from_subject(ctx.subject)` — an explicit projection of the loaded subject into the input representation (§5.3). This is why the pipeline loads before casting.

The base exists **only** so validations see result-state; extraction ignores the changeset's diff entirely (§5.2).

### 5.2 Extraction — `Enact.updates/2`

One extractor, both modes: _the updates map contains exactly the castable fields the caller provided, with their casted values._

```elixir
def updates(changeset, ctx) do
  provided =
    changeset.data.__struct__.fields(ctx.mode)
    |> Enum.filter(&provided?(ctx, &1))

  changeset |> apply_changes() |> dump_embeds() |> Map.take(provided)
end
```

- **Key selection is presence-in-params intersected with the mode's castable fields** (`fields/1`) — uniform for scalars and embeds. Provided-but-uncastable keys (e.g. `slug` on patch) are ignored, consistent with `cast/3` dropping unknown params.
- **Value correctness is independent of base correctness.** For any provided key: a recorded change yields the provided value; no change means the provided value equalled the base, so `apply_changes` yields it anyway. A wrong projection therefore cannot corrupt persisted data — its blast radius is confined to validation behavior. Omitted keys are excluded by presence and never leak base values into the write.
- The PATCH cases resolve as: omitted → absent from updates → untouched. Explicit `null` → present with casted value nil → clears. Provided-identical → present with the same value → harmless no-op write (and visible to audit for free). `[]` on an embed → present with `[]` → clears the array.
- Never use bare `apply_changes/1` output for persistence — it erases omitted-vs-provided.
- **Embed values are dumped to plain maps.** `apply_changes` yields input-schema structs, and `Ecto.Changeset.cast` raises on struct params — so `updates/2` recursively unwraps embed structs into plain atom-keyed maps (schema-driven via `__schema__(:embeds)`; scalar structs like dates and decimals stay intact). The updates map feeds persistence changesets and JSON serializers directly; the cast structs remain recoverable from the changeset via `apply_changes/1` if ever needed.
- **Declared partial embeds** (`partial_embeds/1`, §4.1) are presence-faithful one level down: their dumped maps are filtered to the sub-keys the caller provided (explicit null sub-key → present as nil, a clear; omitted → absent, untouched). This is caller-said interpretation only — the world-merge over the subject's current value stays in `execute/2` (via `Enact.merged/4`), where world-knowledge lives.
- Create correctness falls out: required fields are guaranteed present by `validate_required`; omitted optionals are absent from updates and fall to DB defaults — client-visible behavior identical to a conventional cast-and-insert.

### 5.3 The validation base — `from_subject/1`

In patch mode, validations must see **result-state** — current values where omitted, new values where provided — so that:

- `validate_required` works in the patch changeset head: an omitted-but-populated required field passes (base supplies it via `get_field`); an explicit nil-clear of a required field records a nil change and fails. No special clear-handling helper is needed.
- Cross-field rules read plain Ecto: `get_field(cs, :duration_minutes)` returns the value the record will have — no per-validation subject-fallback idiom (`get_change(...) || subject.field` is both bug-prone under nil-clears and an unlabeled inline projection; it must not appear in application code).

The base is produced by `from_subject/1` on the input module — part of the `Enact.InputSchema` contract (§4.1):

```elixir
@impl true
def from_subject(project) do
  %__MODULE__{
    name: project.name,
    slug: project.slug,
    priority: project.priority,
    # subject → input vocabulary
    owner_id: PublicIds.encode(:user, project.owner_id)
  }

  # embeds intentionally left at structural defaults — never seeded
end
```

Rules:

- **The projection is explicit, owned by the input module, and total over its scalar fields.** It is the single home of the subject→input translation (public-ID rendering, renames, representation conversions) — the same mapping the app's serializers maintain, plausibly shared code. Blind struct-copying (`Map.take(subject, fields)`) is forbidden as an implementation: alignment is a per-module decision to state, not an assumption to inherit.
- **Embeds are never seeded** — they stay at structural defaults (`[]`/`nil`). Array semantics are replace-wholesale; seeding would engage `cast_embed`'s diff-by-identity machinery where no diff exists. Collection-level validations that must run on the `[]`-clear case gate on `Enact.provided?/2`, and cross-field rules needing current items read `ctx.subject` directly.
- **Completeness is testable** (§10): projecting a fully-populated fixture subject must yield a non-nil value for every scalar field. A forgotten field fails CI instead of silently reviving the nil-clear-vs-omitted ambiguity for that field.
- Create mode never calls it; input modules used only by create actions may omit it (guardrail-checked only when a patch-mode action references the module, §9).

### 5.4 `Enact.provided?/2`

`Enact.provided?(ctx, key_or_path)` — providedness in raw params, the reification of "what did the caller say?" at any depth. It lives on the root module, not `Enact.Validations`, because its consumers span the architecture: `updates/2` (extraction), validation gating, and host `execute` interpreters.

- `provided?(ctx, :items)` — top-level key presence (string-or-atom keyed).
- `provided?(ctx, [:items, 2, :quantity])` — path form: atoms descend into maps, integers index into lists. Anything unreachable (missing key, out-of-range index, non-map element) returns `false`; the function **never raises and never converts strings to atoms** — hand-rolled versions using `String.to_existing_atom/1` on client-supplied keys crash on unknown input, which is why the library owns this primitive.

Used by `updates/2` for key selection, by collection-level validations that must run on the `[]`-clear case (which `get_change`-gating would skip), and by host `execute` interpreters that need per-index sub-field providedness (op-batch endpoints implementing per-op merge semantics).

## 6. Validation

All validation lives in changeset pipelines: the action's `validate/2` for operation-specific rules, the input module's `base_validations` for payload-intrinsic rules, and item `changeset/2`s for per-item rules. Input schemas declare shape only (fields, types, embeds); required-ness lives in the mode-specific changeset heads. Rationale: co-dependent and conditional validations are miserable in any schema vocabulary and trivial as functions; Ecto's own schema/changeset split is the precedent.

Patterns:

- **Cheap gates expensive:** `Enact.Validations.check/2` — no-ops if `changeset.valid?` is already false; otherwise applies the given function. All DB-backed checks go through it.
- **Collection-level rules** (cross-item consistency, at-least-one, max-N): parent pipeline; materialize via `apply_changes` (values, not diffs); attach errors to the parent key; run after item validity is established.
- **Result-state reads:** with the base in place (§5.3), `get_field/2` is the standard way to read "the value the record will have" — cross-field rules use it directly. `Enact.provided?/2` gates rules that must run only when the caller touched a key (including `[]`-clears) — the explicit module prefix usefully marks raw-params reads, the sanctioned exception to "validations read the changeset." The `get_change(...) || ctx.subject.field` fallback idiom is forbidden in application code (§5.3).
- **`Enact.Validations.unique/3`:** scoped uniqueness for input changesets (`scope:`, `repo:`, `query:` opts); skips when the field has no change.
- **`Enact.merged/4`:** the result-state view of a partial embed (§4.1 `partial_embeds/1`) — each sub-key reads the caller's casted value where provided (explicit nulls read as clears) and the subject's current value where not; whole-object nulls read as all-nil; keys derive from the schema by default. Lives on the root module because its consumers span validate (merged-result rules) and execute (it is the merge — one shared definition). The presence-gated, sanctioned sibling of the forbidden change-gated fallback.

## 7. Reference resolution — `resolvers/0` + `Enact.Resolve`

Payload references (public-facing IDs like `usr_XXXX`) get their own pipeline step. **Resolution failures are field-level `:invalid` errors (`"not found"` on the field), never `:not_found`** — 404 belongs to the URL subject; and "exists but not yours" must be indistinguishable from "doesn't exist" (enumeration resistance). Genuine capability denials stay in `authorize/1`.

Spec is declarative data (consistent with the data-callback rule; enables the introspection tests in §10):

```elixir
def resolvers do
  [
    # scalar
    owner: {:owner_id, &fetch_owner/2},
    # path form → batch
    milestone_owners: {[:milestones, :owner_id], &fetch_milestone_owners/2}
  ]
end
```

**Scalar fetcher contract:** `(public_id, ctx) → {:ok, struct} | :error | {:error, message}`. Bare `:error` renders the generic `"not found"` field error; `{:error, message}` renders a precise message on the same field through the same propagation path. Skipped when the field has no change (patch composes free: untouched reference survives; provided reference re-resolves and re-authorizes).

**Error precision — the trust-anchor rule.** Collapse is mandatory _outside_ the trust anchor; precision is permitted _inside_ it:

- **Missing vs. wrong-tenant must be indistinguishable** (both → bare `:error` → `"not found"`). If they render differently, probing IDs reveals which exist — the enumeration-resistance property.
- **Deleted / permission-denied within the caller's own tenant may be precise** (`{:error, "has been deactivated"}`, `{:error, "cannot be assigned by your role"}`). The caller can legitimately know these records exist; generic "not found" here is bad UX with zero security payoff.
- **Safety comes from check ordering inside the fetcher**: scope by the trust anchor _first_; emit precise messages only about records the anchor-scoped query returned. (Residual convention, §9; the cross-tenant sweep verifies foreign references produce only the generic message.)

**Path/batch fetcher contract:** `(ids_list, ctx) → %{public_id => struct | {:error, message}}`. Absent ids render the generic `"not found"`; `{:error, message}` values render precise per-item messages (same trust-anchor rule applies). Helper mechanics (library-owned; the manual nested-changeset surgery is acceptable _here_ because it's ~10 tested library lines, not application code):

1. Collect unique non-nil `field` changes across item changesets of the embed.
2. One fetcher call (batching: N items ≠ N queries; scoping written once; duplicates deduped).
3. Items whose id is absent from the result map: `add_error` on the **item** changeset, splice the list back into parent changes, explicitly mark parent invalid. Errors render at correct indices via the same `traverse_errors` path as cast_embed failures.
4. Success: stash in assigns — scalar as the struct (`ctx.assigns.owner`), batch as the lookup map keyed by public id (`ctx.assigns.milestone_owners`; survives duplicates/reordering, makes the execute-side join a map read).
5. Nil item-ids are skipped (mirror scalar behavior); if the id is required, item-level `validate_required` catches it pre-resolve.
6. Implement paths one level deep only; deeper nesting is an API-shape smell until proven otherwise.

**Propagation summary:** resolution failures are ordinary field errors in the same changeset as validation errors — collected without short-circuiting (all bad references surface in one round trip), wrapped as `Enact.Error.invalid(changeset)`, rendered via the host app's `traverse_errors/2` path. To the API consumer a resolution failure is shape-identical to a validation failure: same 422, envelope, and field addressing (per-index nesting included). Resolve tags its errors with metadata (`add_error(cs, field, msg, validation: :resolution)`) so renderers or stable API error codes can distinguish input-format errors from reference errors without string matching; message text and i18n remain host-app renderer concerns.

`execute/2` translates public→internal ids by reading assigns (e.g. `ctx.assigns.owner.id`). Manual splicing into the updates map is acceptable for now; a `put:` option on the spec is the second-use extraction if it proliferates.

## 8. Errors — `Enact.Error`

```elixir
defstruct [:type, :changeset, :reason, meta: %{}]
# type: :invalid | :forbidden | :not_found | :conflict | :internal
# Constructors: invalid/1 (changeset), forbidden/0-1, not_found/0-1, conflict/0-2, internal/1
```

- **Closed taxonomy, HTTP-shaped:** invalid→422, forbidden→403, not_found→404, conflict→409, internal→500. No bespoke error atoms from actions — the renderer must never grow a default clause.
- **`reason` is internal only** (logs/telemetry), never serialized. The only outward-rich type is `:invalid` via the changeset (safe: describes the caller's own input). Rendering = one `ErrorRenderer` using `traverse_errors/2`; handles nested/indexed embed errors with zero per-action knowledge; it is the API-versioning seam.
- **`:conflict`** for optimistic/temporal races (resource claimed between validation and insert, stale_error_field). Input was fine; the world changed.
- **404/403 collapse** is renderer policy (defense in depth; tenant-scoped `load/2` mostly produces `:not_found` for cross-tenant probes anyway). Internally keep both types — different bugs.
- **`:internal` is a bug bucket.** Every production occurrence is either a bug or a missing promotion to a real type. Runner auto-promotes constraint-error changesets from repo failures to `:invalid`.
- **Telemetry:** the runner emits `[:enact, :action, :run]` / `[:enact, :action, :run, :error]` — per-action, per-type metrics for observability tooling and audit trails ("actor X attempted Y, denied :forbidden") with zero action-author involvement. The run event fires after a successful commit but before `after_commit/2`, so a raising side effect cannot suppress the audit record of a committed write. Dry runs emit distinct events (`[:enact, :action, :dry_run]` and `[:enact, :action, :dry_run, :error]`) so attempt-counting and audit trails never conflate previews with real executions — a dry run is still an authorization-relevant event and should be auditable as one.
- `meta` for machine-readable extras (retry_after, stable error codes) only.

## 9. Guardrails — `Enact.Guardrails`

Principle: **every "just don't do X" rule that is mechanically detectable gets detected and raised** — conventions upgrade to invariants.

`assert_valid_input_schema!/1` walks an input module **recursively** (via `__schema__(:embeds)` / `__schema__(:embed, name).related`, with a cycle guard for self-referential embeds) and raises with teaching error messages on:

1. Any scalar field with a non-nil default in `struct(module)` (embed fields excluded — their structural `[]`/`nil` defaults are fine).
2. `__schema__(:primary_key) != []` at any level (the nested-item level is where IDs sneak in).
3. `__schema__(:associations) != []` — embeds only.
4. **Top-level modules only:** missing `changeset/3` or `fields/1` exports, or missing `from_subject/1` on a module referenced by any patch-mode action (the `Enact.InputSchema` contract, §4.1/§5.3) — teaching errors pointing at the behaviour docs. Nested item modules are exempt (they implement `changeset/2` for `cast_embed`; §4.1 asymmetry note).

Invocation: memoized first-`run` check, **plus** a CI test that calls it on every action's input module explicitly (avoids `@after_compile` ordering subtleties while keeping compile-adjacent feedback).

**Residual conventions** (not mechanically checkable; mitigate with the §10 cross-tenant test + greppable single locations):

1. `load/2` and every fetcher must scope by a trust anchor — the actor/tenant when authenticated; a public-by-construction subject for `anonymous?: true` actions (§2.4).
2. Fetchers check the trust anchor first and emit precise error messages only about records the anchor-scoped query returned (§7).
3. Writes go through `Enact.run` — no direct-Repo context functions (social + optional Credo rule).
4. Optional scalar columns are nullable with no default — `NULL` is the single representation of empty, aligning storage, `ctx.subject`, JSON `null`, and stock cast coalescing (the sibling of §4.3's "defaults live in the DB"). `NOT NULL DEFAULT ''` columns force `""` into the input domain and require per-field `""`-preserving casts; reserve them for fields where empty-string is genuinely distinct from absent.

## 10. Required tests (part of the definition of done)

1. **Doc-schema reconciliation (host-app test):** the package's role ends at the introspection manifests (`fields/1`, `resolvers/0`); it knows nothing of OpenApiSpex or any other documentation library and must never grow such a dependency (§1 non-goals). Host apps write a drift test zipping `Input.fields(mode)` against their API-doc source of truth — for OpenApiSpex, each request schema's properties (extendable to types/required).
   - **Resolver coverage (host-app test, package manifests only):** every `*_id` input field has a `resolvers/0` entry, with an explicit per-action allowlist for legitimately opaque `_id` fields (external references, idempotency keys) — exceptions stay visible instead of weakening the rule. Catches "added reference, forgot resolver," which otherwise sends a raw public-id string to persistence.
2. **Cross-tenant sweep:** every action run with a tenant-A actor against tenant-B subject and references → `:not_found` / field errors, and foreign-reference field errors carry only the generic `"not found"` message (never a precise one). Enumerates reference fields from `resolvers/0` specs.
   - **Anonymous variants:** every `anonymous?: true` action run as an anonymous actor against references outside the subject's tenant → field errors; every action _without_ `anonymous?: true` run as an anonymous actor → `:forbidden`; `actor: nil` raises everywhere.
3. **PATCH matrix** per patch action: omitted key untouched; explicit nil clears scalar; explicit nil on a required field → `:invalid`; omitted required-but-populated field passes `validate_required`; `[]` clears array (presence-gated validations still run); provided-identical persists as a harmless no-op write; provided reference re-resolves; absent reference survives.
4. **Create matrix:** omitted optional falls to DB default; explicit nil on required field fails `validate_required`.
5. **Guardrails:** all input modules pass `assert_valid_input_schema!`; a fixture module with a default/PK/association raises with the expected message.
6. **Projection completeness** (host-app, per patch-mode input module): `from_subject/1` on a fully-populated fixture subject yields a non-nil value for every scalar field, and leaves embeds at structural defaults — a forgotten or mistranslated field fails CI instead of silently degrading validation behavior for that field.
7. **Error taxonomy:** each failure class maps to its `Enact.Error` type; `reason` never appears in rendered output; nested resolution errors render at correct indices.
8. Test helper: `assert_invalid(result, on: field)`.

## 11. Module inventory

| Module              | Contents                                                                                                                          | ~Lines |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `Enact`             | `run/3`, `dry_run/3`, pipeline steps, `updates/2`, path-capable `provided?/2`, `merged/4`, digest, transaction/error normalization, telemetry | 120    |
| `Enact.Action`      | behaviour + `__using__` defaults                                                                                                  | 40     |
| `Enact.Context`     | struct                                                                                                                            | 15     |
| `Enact.Actor`       | protocol: `anonymous?/1` + Any/Atom impls                                                                                         | 15     |
| `Enact.InputSchema` | behaviour: `changeset/3`, `fields/1`, `from_subject/1`, `partial_embeds/1` + `cast_input/4` + moduledoc                           | 75     |
| `Enact.Error`       | struct + constructors                                                                                                             | 30     |
| `Enact.Preview`     | struct + canonical digest encoding                                                                                                | 20     |
| `Enact.Resolve`     | scalar + path/batch resolution, item-error splicing                                                                               | 60     |
| `Enact.Validations` | changeset-pipeline combinators: `check/2`, `unique/3`                                                                             | 30     |
| `Enact.Guardrails`  | recursive input-schema assertions                                                                                                 | 40     |
| `Enact.Test`        | `assert_invalid/2`, `assert_rejects_empty_strings/3`, ctx builder, shared test support                                            | 60     |

Packaging: ships as a Hex package from the start, so it can be shared across multiple host applications.

- Dependencies: `ecto` (core only — no `ecto_sql` requirement; changesets ship without database machinery). `telemetry` for the runner events. Nothing else.
- The repo is injected per call (`repo:` option) or set via host-app config (`config :enact, repo: MyApp.Repo`) — the package itself never owns a repo.
- Versioning: start at `0.x` and treat the behaviours (`Enact.Action`, `Enact.InputSchema`), the `Enact.Actor` protocol, the `Enact.Error` and `Enact.Preview` shapes, and the `Enact` module functions (`run/3`, `dry_run/3`, `updates/2`, `provided?/2`) as the compatibility surface across consuming apps. Because multiple codebases consume it, breaking changes to callback signatures or the error taxonomy are the expensive kind — batch them.
- No host-app assumptions: no auth coupling (fetchers own authorization), no HTTP/Phoenix dependency (the ErrorRenderer lives in the host; scope structs work as actors via opacity + `Enact.Actor`), no JSON library, no API-documentation tooling (§10).
- The §10 tests split accordingly: pipeline/guardrail/resolve mechanics are package tests; reconciliation, cross-tenant sweeps, and the PATCH/create matrices are host-app tests (they depend on real actions and schemas). Ship the `assert_invalid` helper and any test support in an `Enact.Test` module so host apps don't reinvent it.

## 12. Dry run / confirmation flow — `Enact.dry_run/3` + `Enact.Preview`

Motivation: agent-facing surfaces (e.g. MCP tools with a confirmation step) need to take user input, validate it fully, and reflect the casted/normalized changes back for confirmation before anything persists.

The pipeline is already staged for this: every step before `execute` is side-effect free (validate/resolve perform DB reads only; the transaction opens at persist). `dry_run/3` runs `load → cast → authorize → validate → resolve`, then stops.

```elixir
Enact.dry_run(ActionModule, params, actor: actor)

{:ok,
 %Enact.Preview{
   action: ActionModule,
   mode: :patch,
   # Enact.updates/2 output — casted, normalized, validated
   updates: %{...},
   # names of resolvers that succeeded — never the structs
   resolved: [:owner],
   # hash binding action, mode, and the canonical updates map
   digest: "sha256:..."
 }}
# identical error surface to run/3
| {:error, %Enact.Error{}}
```

Design decisions:

- **Distinct `%Enact.Preview{}` struct** — callers must be structurally unable to confuse "validated" with "executed". Never a flag on the normal result.
- **Preview carries `updates/2` output, not the changeset.** It is the canonical, post-normalization "what will be persisted" map — the single definition of the diff shared by validation, persistence, and preview. What the user confirms is definitionally what executes.
- **Confirmation digest.** `dry_run` digests the action module, the mode, and the canonically-encoded updates map together (deterministic encoding — sorted keys, stable struct/date encoding; Elixir map ordering is not sufficient). Folding action and mode into the hash makes the guarantee total: a digest minted for one action or mode never confirms another, and input-less actions (whose updates are always `%{}`) don't collapse to one shared digest. `run/3` accepts optional `confirm_digest:`, recomputes post-validation, and returns `:conflict` on mismatch: "the user confirmed _this exact change_" becomes a mechanical guarantee across the confirmation gap. Non-confirmation callers never see it.
- **No reservation semantics (non-goal).** A preview is not a promise; the confirming `run/3` re-executes the full pipeline, and races surface as `:invalid`/`:conflict` normally. If a domain needs "hold this resource during confirmation", model it as an explicit domain action (a hold with a TTL), never as dry-run machinery.
- **Resolved references leak nothing.** The preview lists resolver _names_ that succeeded; loaded structs stay in `ctx.assigns` and never reach the caller (field-leakage risk toward agents). If confirmation UX needs display info ("assigning to Jane Doe"), that is host-app rendering; a `preview/2` option on resolver specs is a deferred second-use extraction (§13).
- **Patch previews carry the provided keys** (`updates/2` semantics, §5.2), and the subject is loaded — host apps render old → new diffs by comparing updates against the subject, no additional machinery.
- **Authorization runs in dry runs** (don't preview what you can't do), and dry runs emit distinct telemetry (§8).

Tests (additions to §10): dry_run performs no writes (assert on the Repo); preview `updates` equals what a subsequent `run` persists for identical params; digest mismatch returns `:conflict`; digest match with changed world state still re-validates; preview never contains resolved structs.

## 13. Deferred (second-use rule — do not implement now)

- Code-interface sugar (`Domain.create_project/2` via `define`)
- `run!` raising variant
- Imperative `resolve/2` escape hatch
- `put:` option on resolver specs (auto-splice internal ids into updates)
- `preview/2` option on resolver specs (safe display fields for confirmation UX)
- `validate_change_if_present/3` helper
- Shared resolvers module (extract at second duplicated fetcher)
- Third input mode (admin/API-version variants)
- Resolver paths deeper than one level
- Mode-aware `base_validations/2`
- DSL frontend / third-party validator adoption (revisit triggers documented in §1)
- **Seeded `on_replace: :update` embeds** — an evaluated alternative to `partial_embeds/1` (§4.1), recorded so the reasoning survives. Design: `from_subject/1` seeds the current `embeds_one` value and the schema declares `on_replace: :update`, so Ecto casts partial params over current data. What it wins: result-state validation natively (item-level `validate_required` works, plain `get_field` returns the merged object, no `Enact.merged/4` call), and zero execute-side merge (`apply_changes` already yields the object to persist). Why `partial_embeds/1` was chosen instead: (1) the updates map would carry result-state for these embeds while remaining delta everywhere else — mixed per-key semantics, against the uniform "updates = what the caller said" contract; (2) the digest would bind resulting state rather than the caller's instruction, which is a genuine semantic fork: delta-binding lets concurrent changes to untouched sub-keys pass (matching the no-reservation stance, fewer spurious conflicts in agent confirmation flows), resulting-binding turns them into `:conflict` (optimistic concurrency on the whole object); (3) the display trade mirrors rather than disappears — resulting state shown means the delta must be diffed host-side for "what changed" display. The validation advantage is largely neutralized by `Enact.merged/4` (one call vs. native `get_field`). Open question before any adoption: whether a whole-object null-clear is expressible under `on_replace: :update` (the nil-cast path routes through `on_replace`; verify against Ecto source). Trigger: real embeds where resulting-state confirmation and item-level required-ness matter more than delta semantics. Would coexist with `partial_embeds/1` as a second declared per-embed contract, not replace it. (Seeding `embeds_many` remains rejected outright: PK-less items give the differ nothing to match, so every seeded item routes through `on_replace` for no benefit.)
