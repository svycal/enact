defmodule Enact.Action do
  @moduledoc """
  The behaviour every action module implements.

  `use Enact.Action` sets `@behaviour Enact.Action` and overridable
  defaults for the optional callbacks — that is its entire body; there is
  no DSL and no code generation.

  Required: `input/0`, `authorize/1`, `execute/2`. An open write is a
  written `authorize/1` returning `true`, never an omitted callback.

  Every callback is either pure data (`config/0`, `input/0`, `resolvers/0`)
  or a single-purpose function over `(changeset | params, ctx)`. The runner
  (`Enact.run/3`) orchestrates them as:

      load → cast → authorize → validate → resolve → execute → after_commit

  """

  alias Enact.Context

  @doc """
  Static action configuration.

  Recognized keys (all optional): `mode: :create | :patch` (default
  `:create`), `anonymous?: boolean` (default `false`).
  """
  @callback config() :: keyword()

  @doc """
  The input-schema module (`Enact.InputSchema`), or `nil` for input-less
  actions (archive, cancel, resend) — the runner then skips cast and
  validate, and `Enact.updates/2` returns `%{}`.
  """
  @callback input() :: module() | nil

  @doc """
  Fetches the subject — the URL-anchored record the action operates on or
  within (the updated record in patch mode; the parent in
  create-under-parent). Always invoked. The default is a no-op that
  returns `:no_subject` (leave `ctx.subject` nil). Returning `nil`
  produces `:not_found`. Must scope by the trust anchor (§9 of the
  design spec). Params are string-keyed — the runner stringifies atom
  keys at the `run`/`dry_run` boundary — and values are uncast. Match
  `%{"id" => id}`, not `params[:id]`.
  """
  @callback load_subject(params :: map(), ctx :: Context.t()) ::
              struct() | nil | :no_subject | {:error, term()}

  @doc """
  Authorizes the actor against the loaded context. Required — a forgotten
  policy is indistinguishable from an open write. Runs before validate —
  unauthorized callers learn nothing about what's invalid.

  Return values:

    * `true` — proceed
    * `false` — `{:error, %Enact.Error{type: :forbidden}}`
    * `{:error, reason}` — `{:error, %Enact.Error{type: :forbidden, reason: reason}}`
      (`{:error, :foo}` → `{:error, %Enact.Error{type: :forbidden, reason: :foo}}`)
    * `{:error, %Enact.Error{}}` — passed through

  `reason` is for logs, telemetry, and the host renderer. Do not echo it
  wholesale. Match host-owned atoms in the renderer when the 403 copy
  should vary; leave the default opaque.

  An open write (any non-anonymous actor; or anyone, on `anonymous?: true`
  actions) is a written `true`, never an omitted callback.
  """
  @callback authorize(ctx :: Context.t()) :: boolean() | {:error, term()}

  @doc """
  Ordinary changeset pipeline for operation-specific rules (payload-
  intrinsic rules belong in the input module's own validations). Not
  invoked for `input: nil` actions.
  """
  @callback validate(changeset :: Ecto.Changeset.t(), ctx :: Context.t()) :: Ecto.Changeset.t()

  @doc """
  Declarative reference-resolution spec: `[name: {field_or_path, fetcher}]`.
  See `Enact.Resolve`.
  """
  @callback resolvers() :: keyword()

  @doc """
  Persists the write. Runs inside `repo.transaction/1`; `{:error, reason}`
  rolls back. A returned `%Ecto.Changeset{}` error (declared constraints)
  is promoted to `:invalid`; any other error becomes `:internal`.
  """
  @callback execute(changeset :: Ecto.Changeset.t(), ctx :: Context.t()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Post-commit side effects (job insertion, analytics). Runs strictly after
  a successful commit, outside the transaction; its return value is
  ignored and it never rolls back. A raise propagates to the caller, but
  the write is already committed and the success telemetry event has
  already been emitted — the audit trail records the write either way.
  """
  @callback after_commit(result :: term(), ctx :: Context.t()) :: term()

  @optional_callbacks [
    config: 0,
    load_subject: 2,
    validate: 2,
    resolvers: 0,
    after_commit: 2
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour Enact.Action

      @impl Enact.Action
      def config, do: []

      @impl Enact.Action
      def load_subject(_params, _ctx), do: :no_subject

      @impl Enact.Action
      def validate(changeset, _ctx), do: changeset

      @impl Enact.Action
      def resolvers, do: []

      @impl Enact.Action
      def after_commit(_result, _ctx), do: :ok

      defoverridable config: 0,
                     load_subject: 2,
                     validate: 2,
                     resolvers: 0,
                     after_commit: 2
    end
  end
end
