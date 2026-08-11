# Phoenix Integration

Enact has no Phoenix dependency, so a host app wires three seams itself: the actor, the controller calling convention, and the error renderer. Every host wires them the same way — this guide is the reference implementation.

## Setup

```elixir
# mix.exs (from GitHub until Enact is published to Hex)
{:enact, github: "svycal/enact"}

# config/config.exs
config :enact, repo: MyApp.Repo
```

## The actor: your scope struct

In Phoenix 1.8+ the recommended actor is the scope struct — actions inherit its role wholesale, and Enact never looks inside it (only your `authorize/1` and fetchers do):

```elixir
Enact.run(CreateProject, params, actor: conn.assigns.current_scope)
```

Teach Enact which scopes are anonymous with a small protocol impl:

```elixir
# lib/my_app/accounts/scope.ex
defimpl Enact.Actor, for: MyApp.Accounts.Scope do
  def anonymous?(%{user: nil}), do: true
  def anonymous?(_scope), do: false
end
```

`actor: nil` always raises — deliberately colliding with `current_scope: nil` on public routes. Public endpoints construct an explicit anonymous scope at the boundary (which can carry session id and IP for rate limiting):

```elixir
# a plug on public pipelines
def assign_public_scope(conn, _opts) do
  assign(conn, :current_scope, MyApp.Accounts.Scope.for_visitor(
    session_id: get_session(conn, :session_id),
    ip: conn.remote_ip
  ))
end
```

Only actions declaring `anonymous?: true` in `config/0` accept an anonymous actor; everything else returns `:forbidden` before any pipeline work. Grep for `anonymous?: true` to audit your unauthenticated write surface.

## Controllers

Phoenix merges path params into `params`, so the subject id (`load/2` reads it) and the body arrive together — pass `params` straight through:

```elixir
defmodule MyAppWeb.ProjectController do
  use MyAppWeb, :controller

  action_fallback MyAppWeb.FallbackController

  alias MyApp.Projects.Actions.{CreateProject, UpdateProject}

  def create(conn, params) do
    with {:ok, project} <- Enact.run(CreateProject, params, actor: conn.assigns.current_scope) do
      conn |> put_status(:created) |> render(:show, project: project)
    end
  end

  def update(conn, params) do
    with {:ok, project} <- Enact.run(UpdateProject, params, actor: conn.assigns.current_scope) do
      render(conn, :show, project: project)
    end
  end
end
```

## Rendering errors

One fallback clause handles every action in the app — the closed taxonomy means this code never grows:

```elixir
defmodule MyAppWeb.FallbackController do
  use MyAppWeb, :controller

  def call(conn, {:error, %Enact.Error{} = error}) do
    conn
    |> put_status(status(error.type))
    |> put_view(json: MyAppWeb.ErrorJSON)
    |> render(:enact, error: error)
  end

  defp status(:invalid), do: :unprocessable_entity
  defp status(:forbidden), do: :forbidden
  defp status(:not_found), do: :not_found
  defp status(:conflict), do: :conflict
  defp status(:internal), do: :internal_server_error
end
```

```elixir
defmodule MyAppWeb.ErrorJSON do
  # :invalid is the only outward-rich type — the changeset describes the
  # caller's own input, so traverse_errors is safe to serialize. Nested and
  # indexed embed errors (including resolver failures) render correctly with
  # zero per-action knowledge.
  def enact(%{error: %Enact.Error{type: :invalid, changeset: changeset}}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  # NEVER serialize error.reason — it is internal-only (logs/telemetry).
  def enact(%{error: %Enact.Error{type: type}}) do
    %{errors: %{detail: detail(type)}}
  end

  defp detail(:forbidden), do: "Forbidden"
  defp detail(:not_found), do: "Not found"
  defp detail(:conflict), do: "Conflict"
  defp detail(:internal), do: "Internal server error"

  defp translate_error({msg, opts}) do
    # Gettext-backed in a real app; this renderer is your API-versioning seam
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
```

Two renderer policies to decide once:

- **404/403 collapse** — rendering `:forbidden` as 404 is defense-in-depth against existence leaks. Keep the two types distinct internally (different bugs); collapse only at the renderer.
- **Stable error codes** — resolver failures carry `validation: :resolution` in the error metadata, so `translate_error/1` can emit machine-readable codes distinguishing reference errors from format errors without string matching.

## Constraint errors and stale races

A `{:error, %Ecto.Changeset{}}` returned from `execute/2` rolls the transaction back and is promoted to `:invalid` — this is how declared constraints (`unique_constraint`, `foreign_key_constraint`) surface as ordinary 422 field errors when the database catches a race that pre-flight validation couldn't.

One caveat: **stale-entry races arrive through the same channel.** `Repo.update(changeset, stale_error_field: :lock_version)` also returns `{:error, changeset}`, so without intervention an optimistic-lock failure renders as `:invalid` — a field error on `:lock_version` — when it is really the "input was fine; the world changed" case that `:conflict` (409) exists for. If an action uses optimistic locking, translate that specific failure in `execute/2`; the runner passes an `%Enact.Error{}` through untouched:

```elixir
@impl Enact.Action
def execute(changeset, ctx) do
  result =
    ctx.subject
    |> Project.changeset(Enact.updates(changeset, ctx))
    |> Ecto.Changeset.optimistic_lock(:lock_version)
    |> ctx.repo.update(stale_error_field: :lock_version)

  case result do
    {:error, %Ecto.Changeset{errors: errors} = failed} ->
      if errors[:lock_version] do
        {:error, Enact.Error.conflict(:stale)}
      else
        # constraint errors keep flowing to :invalid
        {:error, failed}
      end

    other ->
      other
  end
end
```

Related: the changeset in a promoted constraint error is the *persistence* changeset, so keep constraint-bearing field names aligned with the input schema's names (or re-map in `execute/2`) so the rendered field addressing matches your API contract.

If an action would rather never reflect the persistence changeset — it declares no constraints, or its persistence field names don't match the input's — treat an unexpected changeset error as what it is: validation and persistence have drifted, which is a bug, not caller input. Log it for your own introspection and return `:internal` (the runner passes an `%Enact.Error{}` through untouched, and `reason` is never serialized — the caller sees only a generic 500):

```elixir
require Logger

@impl Enact.Action
def execute(changeset, ctx) do
  updates = Enact.updates(changeset, ctx)

  case ctx.repo.insert(Project.changeset(%Project{}, updates)) do
    {:ok, project} ->
      {:ok, project}

    {:error, failed} ->
      Logger.error(
        "#{inspect(__MODULE__)} persistence changeset rejected pre-validated input: " <>
          inspect(failed.errors)
      )

      {:error, Enact.Error.internal(:persistence_rejected)}
  end
end
```

This is the spec's ":internal is a bug bucket" discipline in practice — every occurrence in production logs is a drift to fix, never something to render.

## Background jobs

Same calling convention — reconstruct the actor from stored identity; never bypass:

```elixir
defmodule MyApp.Workers.ArchiveStaleProject do
  use Oban.Worker

  @impl Oban.Worker
  def perform(%{args: %{"project_id" => id, "actor_user_id" => user_id}}) do
    actor = MyApp.Accounts.scope_for_user_id!(user_id)

    case Enact.run(MyApp.Projects.Actions.ArchiveProject, %{"id" => id}, actor: actor) do
      {:ok, _} -> :ok
      # already archived / gone: don't retry
      {:error, %Enact.Error{type: :not_found}} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
```

## Telemetry

Per-action, per-type metrics and audit trails with zero action-author involvement:

```elixir
:telemetry.attach_many(
  "enact-audit",
  [
    [:enact, :action, :success],
    [:enact, :action, :error],
    [:enact, :action, :dry_run],
    [:enact, :action, :dry_run, :error]
  ],
  &MyApp.Audit.handle_enact_event/4,
  nil
)
```

Error events carry `type:` in metadata ("actor X attempted Y, denied :forbidden"). Dry runs emit distinct events, so previews are auditable without inflating execution counts.

## Confirmation flows (agent surfaces, MCP tools)

```elixir
{:ok, preview} = Enact.dry_run(UpdateProject, params, actor: actor)
# reflect preview.updates back for confirmation; render old → new diffs by
# comparing against the subject; then:
{:ok, project} = Enact.run(UpdateProject, params, actor: actor, confirm_digest: preview.digest)
```

The digest binds action, mode, and the exact updates map — `:conflict` on any drift. The preview lists resolver names only; if the confirmation UX needs display info ("assigning to Jane Doe"), render it host-side.
