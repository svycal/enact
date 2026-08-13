defmodule Enact.Action do
  @moduledoc """
  The behaviour every action module implements.

  `use Enact.Action` sets `@behaviour Enact.Action` and overridable
  defaults for the optional callbacks — that is its entire body; there is
  no DSL and no code generation.

  Every callback is either pure data (`config/0`, `input/0`, `resolvers/0`)
  or a single-purpose function over `(changeset | params, ctx)`. The runner
  (`Enact.run/3`) orchestrates them as:

      load → cast → authorize → validate → resolve → execute → after_commit

  """

  alias Enact.Context

  @doc """
  Static action configuration.

  Recognized keys (all optional): `mode: :create | :patch` (default
  `:create`), `loads_subject?: boolean` (default `false`), `anonymous?:
  boolean` (default `false`).
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
  create-under-parent). Only invoked when `loads_subject?: true`; returning
  `nil` produces `:not_found`. Must scope by the trust anchor (§9 of the
  design spec).
  """
  @callback load(params :: map(), ctx :: Context.t()) :: struct() | nil | {:error, term()}

  @doc """
  Authorizes the actor against the loaded context. `false` (or an error
  tuple) produces `:forbidden`. Runs before validate — unauthorized callers
  learn nothing about what's invalid.
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

  defmacro __using__(_opts) do
    quote do
      @behaviour Enact.Action

      @impl Enact.Action
      def config, do: []

      @impl Enact.Action
      def load(_params, _ctx), do: nil

      @impl Enact.Action
      def authorize(_ctx), do: true

      @impl Enact.Action
      def validate(changeset, _ctx), do: changeset

      @impl Enact.Action
      def resolvers, do: []

      @impl Enact.Action
      def after_commit(_result, _ctx), do: :ok

      defoverridable config: 0,
                     load: 2,
                     authorize: 1,
                     validate: 2,
                     resolvers: 0,
                     after_commit: 2
    end
  end
end
