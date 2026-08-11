# Enact

A thin, behaviour-based action layer for application write operations — **Plug for writes**. Enact standardizes the shape of every write:

```
load → cast → authorize → validate → resolve → execute → after_commit
```

The value is the uniform pipeline shape, the actor context, and the closed error taxonomy — not any novel validation or persistence machinery. **Enact orchestrates; Ecto does the work**: validation is Ecto changesets, input casting is Ecto embedded schemas, persistence is your existing schemas and changesets. No DSL, no parallel type system, no validation vocabulary.

## Installation

```elixir
def deps do
  [
    {:enact, "~> 0.1.0"}
  ]
end
```

Configure the default repo (or pass `repo:` per call):

```elixir
config :enact, repo: MyApp.Repo
```

## A complete action

```elixir
defmodule MyApp.Projects.CreateProject do
  use Enact.Action

  @impl Enact.Action
  def input, do: MyApp.Inputs.ProjectInput

  @impl Enact.Action
  def authorize(ctx), do: MyApp.Policy.can?(ctx.actor, :create_project)

  @impl Enact.Action
  def resolvers do
    [owner: {:owner_id, &MyApp.Fetchers.fetch_org_user/2}]
  end

  @impl Enact.Action
  def execute(changeset, ctx) do
    updates =
      changeset
      |> Enact.updates(ctx)
      |> Map.put(:owner_id, ctx.assigns.owner.id)

    %MyApp.Project{org_id: ctx.actor.org.id}
    |> MyApp.Project.changeset(updates)
    |> ctx.repo.insert()
  end

  @impl Enact.Action
  def after_commit(project, _ctx) do
    MyApp.Analytics.track(:project_created, project)
  end
end
```

Called identically from controllers, background jobs, tests, and IEx:

```elixir
case Enact.run(CreateProject, params, actor: conn.assigns.current_scope) do
  {:ok, project} -> ...
  {:error, %Enact.Error{type: :invalid, changeset: changeset}} -> ...
end
```

The actor is always explicit and required — `actor: nil` raises, and every write path answers "as whom?". Anonymous callers pass an explicit anonymous actor (see `Enact.Actor`), permitted only by actions declaring `anonymous?: true`.

## Input schemas are just Ecto

Inputs are embedded-schema modules implementing the `Enact.InputSchema` behaviour — `changeset/3` heads per mode, a `fields/1` introspection manifest, and (for patch-mode use) a `from_subject/1` projection that lets `validate_required` and cross-field `get_field/2` rules work unmodified on PATCH:

```elixir
defmodule MyApp.Inputs.ProjectInput do
  use Ecto.Schema
  import Ecto.Changeset

  @behaviour Enact.InputSchema

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
    base |> cast(params, @all) |> validate_required(@required)
  end

  def changeset(base, params, :patch) do
    base |> cast(params, @patch) |> validate_required(@required)
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

`Enact.dry_run/3` runs everything up to (not including) execute and returns an `%Enact.Preview{}` — the exact updates map a real run would persist, plus a digest for confirmation flows:

```elixir
{:ok, preview} = Enact.dry_run(UpdateProject, params, actor: actor)
# show preview.updates to the user...
{:ok, project} = Enact.run(UpdateProject, params, actor: actor, confirm_digest: preview.digest)
```

A digest mismatch returns `:conflict` — "the user confirmed this exact change" is a mechanical guarantee.

## Telemetry

The runner emits `[:enact, :action, :success]`, `[:enact, :action, :error]`, and distinct `[:enact, :action, :dry_run]` events with per-action, per-type metadata — observability and audit trails with zero action-author involvement.

## Testing

`Enact.Test` ships `assert_invalid/2`, `build_ctx/1`, and `errors_on/1` so host apps don't reinvent them.

## Design

The full design specification — including the rationale for every decision — lives in [spec.md](spec.md).
