# Phoenix Integration

Enact has no Phoenix dependency, so a host app wires three seams itself: the actor, the controller calling convention, and the error renderer. Every host wires them the same way — this guide is the reference implementation.

## Setup

```elixir
# mix.exs
{:enact, "~> 0.1.0"}

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
