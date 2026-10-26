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

      load → authorize → rate limit → cast → validate → resolve → execute → after_commit

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
  keys at the `run`/`dry_run`/`subject`/`authorized` boundary — and values are uncast. Match
  `%{"id" => id}`, not `params[:id]`.
  """
  @callback load_subject(params :: map(), ctx :: Context.t()) ::
              struct() | nil | :no_subject | {:error, term()}

  @doc """
  Authorizes the actor against the loaded context. Required — a forgotten
  policy is indistinguishable from an open write. Runs before cast —
  unauthorized callers trigger no input work.

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
  Rate-limit buckets for this call: a list of `{key, window_ms, limit}`,
  each allowing at most `limit` writes per `window_ms` milliseconds for
  `key`. The default returns `[]`.

  The runner calls it after `authorize/1` and before cast, in
  `Enact.run/3` and `Enact.dry_run/3`. `ctx` has the actor, subject, raw
  params, and passthrough assigns. If any bucket is full, the call
  returns `{:error, %Enact.Error{type: :rate_limited}}`, with
  `meta.retry_after_ms` set to the longest wait among the full buckets.

  Dry runs check buckets without counting. Runs count one write against
  every bucket after `repo.transaction/1` returns `{:ok, _}`, so an
  invalid or rolled-back run uses no slot. If you call `Enact.run/3`
  inside your own transaction, the runner counts before your transaction
  commits, and a rollback of your transaction still uses the slot.
  Concurrent runs that pass the check together can each commit, so a
  bucket can exceed `limit` by the number of runs in flight.

  The runner does not namespace keys by action. Actions that return the
  same `{key, window_ms}` share a bucket. Include the action or a feature
  name in the key unless you want that:

      @impl Enact.Action
      def rate_limits(ctx) do
        [
          {"team_invite:scope:\#{ctx.subject.id}", :timer.minutes(10), 10},
          {"team_invite:user:\#{ctx.actor.id}", :timer.hours(1), 15}
        ]
      end

  The adapter set in `config :enact, rate_limiter: MyApp.RateLimiter`
  stores the buckets (see `Enact.RateLimiter`). Limits based on data, such as a cap on pending
  records, belong in `validate/2`.
  """
  @callback rate_limits(ctx :: Context.t()) :: [
              {key :: term(), window_ms :: pos_integer(), limit :: pos_integer()}
            ]

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
    rate_limits: 1,
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
      def rate_limits(_ctx), do: []

      @impl Enact.Action
      def validate(changeset, _ctx), do: changeset

      @impl Enact.Action
      def resolvers, do: []

      @impl Enact.Action
      def after_commit(_result, _ctx), do: :ok

      defoverridable config: 0,
                     load_subject: 2,
                     rate_limits: 1,
                     validate: 2,
                     resolvers: 0,
                     after_commit: 2
    end
  end
end
