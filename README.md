# Enact

A thin, behaviour-based action layer for application write operations. Enact standardizes the shape of every write:

```
load → cast → authorize → validate → resolve → execute → after_commit
```

The value is the uniform pipeline shape, the actor context, and the closed error taxonomy — not any novel validation or persistence machinery. **Enact orchestrates; Ecto does the work**: validation is Ecto changesets, input casting is Ecto embedded schemas, persistence is your existing schemas and changesets. No DSL, no parallel type system, no validation vocabulary.

## Installation

Enact isn't published to Hex yet — install it from GitHub:

```elixir
def deps do
  [
    {:enact, github: "svycal/enact"}
  ]
end
```

Configure the default repo (or pass `repo:` per call):

```elixir
config :enact, repo: MyApp.Repo
```

## A complete action

```elixir
defmodule MyApp.Projects.Actions.CreateProject do
  use Enact.Action

  alias MyApp.Accounts
  alias MyApp.Projects.Inputs.ProjectInput
  alias MyApp.Projects.Project

  @impl Enact.Action
  def input, do: ProjectInput

  @impl Enact.Action
  def authorize(ctx), do: MyApp.Policy.can?(ctx.actor, :create_project)

  @impl Enact.Action
  def resolvers do
    [owner: {:owner_id, &fetch_owner/2}]
  end

  @impl Enact.Action
  def execute(changeset, ctx) do
    updates =
      changeset
      |> Enact.updates(ctx)
      |> Map.put(:owner_id, ctx.assigns.owner.id)

    %Project{org_id: ctx.actor.org.id}
    |> Project.changeset(updates)
    |> ctx.repo.insert()
  end

  @impl Enact.Action
  def after_commit(project, _ctx) do
    MyApp.Analytics.track(:project_created, project)
  end

  # the context owns the trust-anchor-scoped query; the fetcher adapts
  # its result to the resolver contract
  defp fetch_owner(public_id, ctx) do
    case Accounts.get_org_user(ctx.actor, public_id) do
      nil -> :error
      user -> {:ok, user}
    end
  end
end
```

Application callers go through a context one-liner that forwards to `Enact.run/3` (see the Phoenix guide). Action tests and IEx may call the runner directly:

```elixir
case Projects.create_project(params, actor: conn.assigns.current_scope) do
  {:ok, project} -> ...
  {:error, %Enact.Error{type: :invalid, changeset: changeset}} -> ...
end
```

The actor is always explicit and required — `actor: nil` raises, and every write path answers "as whom?". Anonymous callers pass an explicit anonymous actor (see `Enact.Actor`), permitted only by actions declaring `anonymous?: true`.

## Input schemas are just Ecto

Inputs are embedded-schema modules implementing the `Enact.InputSchema` behaviour — `changeset/3` heads per mode, a `fields/1` introspection manifest, and (for patch-mode use) a `from_subject/1` projection that lets `validate_required` and cross-field `get_field/2` rules work unmodified on PATCH:

```elixir
defmodule MyApp.Projects.Inputs.ProjectInput do
  use Ecto.Schema
  use Enact.InputSchema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :name, :string
    field :slug, :string
    field :owner_id, :string
  end

  @all ~w(name slug owner_id)a
  @patch @all -- [:slug]
  # owner_id required, so the resolver always runs and execute can rely
  # on ctx.assigns.owner being present
  @required ~w(name slug owner_id)a

  @impl Enact.InputSchema
  def changeset(base, params, :create) do
    base
    |> cast_input(params, @all)
    |> validate_required(@required)
  end

  def changeset(base, params, :patch) do
    base
    |> cast_input(params, @patch)
    |> validate_required(@required)
  end

  @impl Enact.InputSchema
  def fields(:create), do: @all
  def fields(:patch), do: @patch

  @impl Enact.InputSchema
  def from_subject(project) do
    %__MODULE__{
      name: project.name,
      slug: project.slug,
      owner_id: MyApp.PublicIds.encode(:user, project.owner_id)
    }
  end
end
```

`Enact.updates/2` extracts exactly the fields the caller provided, with their casted values — so PATCH semantics fall out: omitted keys are untouched, explicit `null` clears, arrays replace wholesale. `Enact.Guardrails` mechanically enforces the input-schema invariants (no field defaults, no primary keys, no associations) on first run and in CI.

## Errors

Every failure is an `%Enact.Error{}` with one of five HTTP-shaped types: `:invalid` (422, carries the changeset), `:forbidden` (403), `:not_found` (404), `:conflict` (409), `:internal` (500). One renderer in your app handles all of them; actions never invent bespoke error atoms. Reference-resolution failures are field-level `"not found"` errors indistinguishable from validation failures — and cross-tenant probes are indistinguishable from nonexistent records.

## Dry runs and confirmation

`Enact.dry_run/3` runs everything up to (not including) execute and returns an `%Enact.Preview{}` — the exact updates map a real run would persist, the loaded subject, and a digest for confirmation flows:

```elixir
{:ok, preview} = Projects.update_project_dry_run(params, actor: actor)
# show preview.updates to the user...
{:ok, project} =
  Projects.update_project(params, actor: actor, confirm_digest: preview.digest)
```

A digest mismatch returns `:conflict` — "the user confirmed this exact change to this record" is a mechanical guarantee.

## Telemetry

The runner emits `[:enact, :action, :run]`, `[:enact, :action, :run, :error]`, and distinct `[:enact, :action, :dry_run]` events with per-action, per-type metadata — observability and audit trails with zero action-author involvement.

## Testing

`Enact.Test` ships `assert_invalid/2`, `build_ctx/1`, and `errors_on/1` so host apps don't reinvent them.

## Documentation

- [Usage Rules](usage-rules.md) — the condensed do's and don'ts for writing actions; sync it into your agent instructions (CLAUDE.md / AGENTS.md) with [usage_rules](https://hex.pm/packages/usage_rules)
- [Change Detection](guides/change-detection.md) — how the validation base, presence-gated extraction, and PATCH fidelity actually work, and why `force_changes:`-style workarounds never appear
- [Phoenix Integration](guides/phoenix-integration.md) — actor/scope wiring, the reference FallbackController and error renderer, Inertia form posts, background jobs, telemetry
- [Recipes](guides/recipes.md) — worked examples: embedded data end-to-end, flattening embeds into columns, reading resolver assigns, MCP dry-run confirmation flows, empty-string-at-rest columns, partial updates on singular embeds
- [Testing Host Applications](guides/testing.md) — copy-paste templates for the host-side test obligations (cross-tenant sweep, PATCH/create matrices, projection completeness, resolver coverage, guardrails in CI)
- [Design Specification](spec.md) — the authoritative design, including the rationale for every decision
