# Phoenix Integration

Enact has no Phoenix dependency. A host application wires four integration points itself: the actor, the context calling convention, the controller, and the error renderer. This guide provides reference implementations for each.

## Setup

```elixir
# mix.exs (from GitHub until Enact is published to Hex)
{:enact, github: "svycal/enact"}

# config/config.exs
config :enact, repo: MyApp.Repo
```

## Contexts

Phoenix contexts remain the application API. Controllers, LiveViews, and jobs call context functions; those functions are one-liners that forward to `Enact.run/3` (or `dry_run/3`). The action module is the write; the context is the name the rest of the app uses.

```elixir
# lib/my_app/projects.ex
defmodule MyApp.Projects do
  alias MyApp.Projects.Actions.{ArchiveProject, CreateProject, UpdateProject}

  def create_project(params, opts), do: Enact.run(CreateProject, params, opts)
  def update_project(params, opts), do: Enact.run(UpdateProject, params, opts)
  def archive_project(params, opts), do: Enact.run(ArchiveProject, params, opts)

  def create_project_dry_run(params, opts), do: Enact.dry_run(CreateProject, params, opts)
  def update_project_dry_run(params, opts), do: Enact.dry_run(UpdateProject, params, opts)

  # reads and load_subject fetchers stay here
end
```

Keep those bodies as a single `Enact.run` / `Enact.dry_run` call. Do not reshape params, stamp persistable fields, or preload records into `assigns:` — that work belongs in the action (`execute/2`, `load_subject/2`, `resolvers/0`). `opts` pass through unchanged so `:actor`, `:repo`, `:assigns`, and `:confirm_digest` work as they do on `Enact.run/3`.

The one-liners may be generated instead of written by hand:

```elixir
defmodule MyApp.Projects do
  alias MyApp.Projects.Actions.{ArchiveProject, CreateProject, UpdateProject}

  use Enact.Delegates, actions: [CreateProject, UpdateProject, ArchiveProject]

  # reads and load_subject fetchers stay here
end
```

Names come from the last segment of each action module (`CreateProject` → `create_project` / `create_project_dry_run`). Both wrappers are generated for every listed action. Handwritten delegates remain valid; the helper is opt-in.

Action tests and IEx may still call `Enact.run/3` directly. That is the implementation API, not a second door for controllers.

## The actor: your scope struct

In Phoenix 1.8+, the recommended actor is the scope struct. Enact never reads the actor itself; only your `authorize/1` callbacks and fetchers do.

```elixir
Projects.create_project(params, actor: conn.assigns.current_scope)
```

Implement the `Enact.Actor` protocol for your scope struct so Enact can identify anonymous scopes:

```elixir
# lib/my_app/accounts/scope.ex
defimpl Enact.Actor, for: MyApp.Accounts.Scope do
  def anonymous?(%{user: nil}), do: true
  def anonymous?(_scope), do: false
end
```

`actor: nil` always raises. This intentionally conflicts with `current_scope: nil` on public routes: public endpoints must construct an explicit anonymous scope at the boundary. An anonymous scope can carry a session ID and IP for rate limiting:

```elixir
# a plug on public pipelines
def assign_public_scope(conn, _opts) do
  assign(conn, :current_scope, MyApp.Accounts.Scope.for_visitor(
    session_id: get_session(conn, :session_id),
    ip: conn.remote_ip
  ))
end
```

Only actions that declare `anonymous?: true` in `config/0` accept an anonymous actor. All other actions return `:forbidden` before any pipeline work runs. To audit the unauthenticated write surface, search the codebase for `anonymous?: true`.

### Without scopes

The scope pattern is not required. The actor is opaque to Enact, so any term works. In an application that assigns `current_user`, pass it directly:

```elixir
Projects.create_project(params, actor: conn.assigns.current_user)
```

Authenticated actors need no `Enact.Actor` implementation; the fallback returns `false` for any term. Your `authorize/1` callbacks and fetchers read `ctx.actor` as a user struct instead of a scope.

The rule for public endpoints is unchanged: never pass `nil`. The `:anonymous` atom is a built-in anonymous actor:

```elixir
Bookings.create_booking(params, actor: :anonymous)
```

Unlike an anonymous scope, `:anonymous` carries no session ID or IP. If your `anonymous?: true` actions need those for rate limiting or auditing, use a scope-shaped actor instead.

## Controllers

Phoenix merges path params into `params`, so the subject ID (read by `load_subject/2`) and the request body arrive together. Pass `params` through unchanged. Jobs and tests may pass atom keys — the runner stringifies them, so actions always see the same string-keyed shape:

```elixir
defmodule MyAppWeb.ProjectController do
  use MyAppWeb, :controller

  action_fallback MyAppWeb.FallbackController

  alias MyApp.Projects

  def create(conn, params) do
    with {:ok, project} <- Projects.create_project(params, actor: conn.assigns.current_scope) do
      conn |> put_status(:created) |> render(:show, project: project)
    end
  end

  def update(conn, params) do
    with {:ok, project} <- Projects.update_project(params, actor: conn.assigns.current_scope) do
      render(conn, :show, project: project)
    end
  end
end
```

## Inertia / HTML form posts

JSON controllers can `with` on the context function because success is a render and every error is a status. Inertia form posts are different: success, `:invalid`, and `:conflict` are Phoenix `redirect/2` (Inertia intercepts those). `:invalid` in particular is not a 422 page — `assign_errors/2` (from [inertia-phoenix](https://github.com/inertiajs/inertia-phoenix)) stashes the changeset and the next GET paints the form. That is the Inertia contract, not Enact's.

`:forbidden`, `:not_found`, and `:internal` still belong to `action_fallback`. Return the error tuple; do not call the fallback module from the helper. `action_fallback` only runs when the action returns something other than a `%Plug.Conn{}`.

```elixir
# lib/my_app_web/enact.ex
defmodule MyAppWeb.Enact do
  import Inertia.Controller
  import Phoenix.Controller

  def enact_redirect(result, conn, opts) do
    case result do
      {:ok, _} ->
        conn
        |> put_flash(:info, Keyword.fetch!(opts, :success_flash))
        |> redirect(to: Keyword.fetch!(opts, :success_path))

      {:error, %Enact.Error{type: :invalid, changeset: changeset}} ->
        conn
        |> assign_errors(changeset)
        |> redirect(to: Keyword.fetch!(opts, :invalid_path))

      {:error, %Enact.Error{type: :conflict}} ->
        conn
        |> put_flash(:error, Keyword.fetch!(opts, :conflict_flash))
        |> redirect(to: Keyword.get(opts, :conflict_path, Keyword.fetch!(opts, :success_path)))

      {:error, %Enact.Error{type: type} = error}
      when type in [:forbidden, :not_found, :internal] ->
        {:error, error}
    end
  end
end
```

```elixir
def create(conn, params) do
  params
  |> Projects.create_project(actor: conn.assigns.current_scope)
  |> enact_redirect(conn,
    success_flash: "Project created",
    success_path: ~p"/projects",
    invalid_path: ~p"/projects/new",
    conflict_flash: "Project could not be created"
  )
end
```

If the success redirect needs the created record (`~p"/projects/#{project}"`), take it from `{:ok, value}`. Conflict has no new record, so that path cannot be the conflict default.

Import the helper from `use MyAppWeb, :controller` if you want it on every controller. Keep the name prefixed (`enact_redirect/3`) so it does not collide with `Phoenix.Controller.redirect/2`, and import with `only:` so later host helpers do not leak into API controllers.

API controllers should not use this helper. They stay on `with {:ok, record} <- Projects.create_project(...)`.

## Rendering errors

One fallback clause handles every action. Because the error taxonomy is closed, this code does not change as actions are added:

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
  # :invalid is the only type that carries caller-visible detail. The
  # changeset describes the caller's own input, so traverse_errors is safe
  # to serialize. Nested and indexed embed errors (including resolver
  # failures) render correctly with no per-action code.
  def enact(%{error: %Enact.Error{type: :invalid, changeset: changeset}}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  # Do not serialize error.reason — it is internal-only (logs/telemetry).
  def enact(%{error: %Enact.Error{type: type}}) do
    %{errors: %{detail: detail(type)}}
  end

  defp detail(:forbidden), do: "Forbidden"
  defp detail(:not_found), do: "Not found"
  defp detail(:conflict), do: "Conflict"
  defp detail(:internal), do: "Internal server error"

  defp translate_error({msg, opts}) do
    # Gettext-backed in a real app. This renderer is the API-versioning seam.
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
```

Two renderer policies to decide:

- **404/403 collapse.** Rendering `:forbidden` as 404 prevents responses from revealing that a resource exists. Keep the two types distinct internally; collapse only at the renderer. The policy can be format-specific: HTML (and Inertia) often collapse, JSON APIs often keep 403. Put the clause above the catch-all `%Enact.Error{}` head:

  ```elixir
  def call(conn, {:error, %Enact.Error{type: :forbidden}}) do
    if get_format(conn) == "html" do
      call(conn, {:error, :not_found})
    else
      call(conn, {:error, :forbidden})
    end
  end
  ```

- **Stable error codes.** Resolver failures carry `validation: :resolution` in the error metadata, so `translate_error/1` can emit machine-readable codes that distinguish reference errors from format errors without string matching.

## Constraint errors and stale races

A `{:error, %Ecto.Changeset{}}` returned from `execute/2` rolls the transaction back and is promoted to `:invalid`. This is how declared constraints (`unique_constraint`, `foreign_key_constraint`) surface as ordinary 422 field errors when the database catches a race that pre-flight validation could not.

Stale-entry races arrive through the same channel. `Repo.update(changeset, stale_error_field: :lock_version)` also returns `{:error, changeset}`, so without intervention an optimistic-lock failure renders as `:invalid` with a field error on `:lock_version`. The correct type for that case is `:conflict` (409): the input was valid, but the record changed. If an action uses optimistic locking, translate that failure in `execute/2`. The runner passes an `%Enact.Error{}` through unchanged:

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
        # constraint errors continue to flow to :invalid
        {:error, failed}
      end

    other ->
      other
  end
end
```

The changeset in a promoted constraint error is the persistence changeset, not the input changeset. Keep constraint-bearing field names aligned with the input schema's names, or re-map them in `execute/2`, so the rendered field addressing matches your API contract.

Some actions should never reflect the persistence changeset to callers — for example, when the action declares no constraints, or when persistence field names do not match the input's. In that case, an unexpected changeset error indicates that validation and persistence have drifted, which is a bug rather than caller input. Log it and return `:internal`. The `reason` field is never serialized, so the caller sees only a generic 500:

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

Every `:internal` occurrence in production logs is a defect to fix. It is never rendered to callers.

## Background jobs

Background jobs use the same calling convention. Reconstruct the actor from stored identity; do not bypass the context (or the action behind it):

```elixir
defmodule MyApp.Workers.ArchiveStaleProject do
  use Oban.Worker

  alias MyApp.Projects

  @impl Oban.Worker
  def perform(%{args: %{"project_id" => id, "actor_user_id" => user_id}}) do
    actor = MyApp.Accounts.scope_for_user_id!(user_id)

    case Projects.archive_project(%{"id" => id}, actor: actor) do
      {:ok, _} -> :ok
      # already archived or deleted: don't retry
      {:error, %Enact.Error{type: :not_found}} -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
```

## Telemetry

The runner emits telemetry events for every action. Attach a handler for metrics and audit trails:

```elixir
:telemetry.attach_many(
  "enact-audit",
  [
    [:enact, :action, :run],
    [:enact, :action, :run, :error],
    [:enact, :action, :dry_run],
    [:enact, :action, :dry_run, :error]
  ],
  &MyApp.Audit.handle_enact_event/4,
  nil
)
```

Error events carry `type:` in metadata, so a handler can record entries such as "actor X attempted Y, denied :forbidden". Dry runs emit separate events, so previews are auditable without inflating execution counts.

## Confirmation flows (agent surfaces, MCP tools)

```elixir
{:ok, preview} = Projects.update_project_dry_run(params, actor: actor)
# present preview.updates for confirmation (diff against preview.subject), then:
{:ok, project} =
  Projects.update_project(params, actor: actor, confirm_digest: preview.digest)
```

The digest binds the action, mode, locator params, and updates map; any difference between the previewed change and the confirming run returns `:conflict`. Diff `preview.updates` against `preview.subject`. The preview lists resolver names only; if the confirmation UI needs display information (for example, the resolved user's name), render it host-side from your own reads.
