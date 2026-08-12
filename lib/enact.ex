defmodule Enact do
  @moduledoc """
  A thin, behaviour-based action layer for application write operations.

  Enact standardizes the shape of every write:

      load → cast → authorize → validate → resolve → execute → after_commit

  Actions implement `Enact.Action`; input casting and validation are plain
  Ecto via `Enact.InputSchema` modules; results are `{:ok, result}` or
  `{:error, %Enact.Error{}}` with a closed, HTTP-shaped error taxonomy.

      Enact.run(CreateProject, params, actor: conn.assigns.current_scope)

  ## Options

    * `:actor` — required; opaque to Enact (only the action's `authorize/1`
      and fetchers read it). `actor: nil` always raises `ArgumentError` —
      anonymous callers pass an explicit anonymous actor instead (see
      `Enact.Actor`), permitted only by actions declaring `anonymous?: true`.
    * `:repo` — the Ecto repo; defaults to `config :enact, repo: MyApp.Repo`.
    * `:assigns` — optional map merged into `ctx.assigns`, the documented
      channel for request metadata (IP, session id) that isn't part of the
      actor. Resolver-stashed keys are merged after and win on collision.
      Never pass pre-loaded domain records here — record fetching belongs
      in `load/2` (URL subject) or `resolvers/0` (body references).

  ## Error normalization

    * `load/2` returning `nil` → `:not_found`
    * `authorize/1` returning `false` → `:forbidden`
    * post-validate invalid changeset → `:invalid` (one response carries
      all cast + validation errors; there is no cast-stage fast-fail)
    * `%Ecto.Changeset{}` error from execute (declared constraints) →
      promoted to `:invalid`
    * any other execute failure → `:internal`

  ## Telemetry

  The runner emits (measurements `%{duration: native_time}`; metadata
  `%{action:, mode:, actor:}`; error events additionally carry `type:`,
  the `Enact.Error` type):

    * `[:enact, :action, :success]` / `[:enact, :action, :error]`
    * `[:enact, :action, :dry_run]` / `[:enact, :action, :dry_run, :error]`
      — distinct events so attempt-counting and audit trails never
      conflate previews with real executions
  """

  alias Enact.{Actor, Context, Error, Preview}

  @doc """
  Runs an action through the full pipeline.

  Returns `{:ok, result}` (whatever `execute/2` produced) or
  `{:error, %Enact.Error{}}`.

  Accepts one option beyond the shared set: `:confirm_digest` — a digest
  from a prior `dry_run/3` preview. The runner recomputes the digest
  post-validation and returns `:conflict` on mismatch, making "the user
  confirmed this exact change" a mechanical guarantee across the
  confirmation gap. Non-confirmation callers never pass it.
  """
  @spec run(module(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def run(action, params, opts) when is_atom(action) and is_map(params) and is_list(opts) do
    {config, ctx} = build(action, params, opts)
    start = System.monotonic_time()

    result =
      with {:ok, changeset, ctx, _resolved} <- pre_execute(action, config, ctx),
           :ok <- check_digest(action, changeset, ctx, opts),
           {:ok, result} <- persist(action, changeset, ctx) do
        action.after_commit(result, ctx)
        {:ok, result}
      end

    emit(result, :run, action, ctx, start)
    result
  end

  @doc """
  Runs the side-effect-free front of the pipeline — cast, load, authorize,
  validate, resolve — then stops before any write, returning
  `{:ok, %Enact.Preview{}}` or the identical error surface to `run/3`.

  Built for confirmation flows (agent-facing surfaces, MCP tools): the
  preview reflects the casted, normalized updates back for confirmation,
  and its digest feeds `run/3`'s `:confirm_digest` option. Authorization
  runs (don't preview what you can't do), and distinct telemetry events
  are emitted so audit trails never conflate previews with executions.
  """
  @spec dry_run(module(), map(), keyword()) :: {:ok, Preview.t()} | {:error, Error.t()}
  def dry_run(action, params, opts) when is_atom(action) and is_map(params) and is_list(opts) do
    {config, ctx} = build(action, params, opts)
    start = System.monotonic_time()

    result =
      case pre_execute(action, config, ctx) do
        {:ok, changeset, ctx, resolved} ->
          updates = updates(changeset, ctx)

          {:ok,
           %Preview{
             action: action,
             mode: ctx.mode,
             updates: updates,
             resolved: resolved,
             digest: Preview.digest(action, ctx.mode, updates)
           }}

        {:error, error} ->
          {:error, error}
      end

    emit(result, :dry_run, action, ctx, start)
    result
  end

  @doc """
  Whether the caller provided a key (or path) in the raw params — the
  reification of "what did the caller say?".

  A key is provided even when its value is `nil` (an explicit null-clear
  is a statement). Accepts a single atom for top-level presence, or a path
  where atoms descend into maps (string- or atom-keyed) and non-negative
  integers index into lists. Anything unreachable — missing key,
  out-of-range index, non-map element — returns `false`. Never raises and
  never converts strings to atoms.

      iex> ctx = %Enact.Context{params: %{"note" => nil, "items" => [%{"qty" => 1}]}}
      iex> Enact.provided?(ctx, :note)
      true
      iex> Enact.provided?(ctx, :missing)
      false
      iex> Enact.provided?(ctx, [:items, 0, :qty])
      true
      iex> Enact.provided?(ctx, [:items, 5, :qty])
      false
      iex> Enact.provided?(ctx, [:note, :deep])
      false
  """
  @spec provided?(Context.t(), atom() | [atom() | non_neg_integer()]) :: boolean()
  def provided?(%Context{params: params}, key) when is_atom(key), do: walk(params, [key])
  def provided?(%Context{params: params}, path) when is_list(path), do: walk(params, path)

  defp walk(_value, []), do: true

  defp walk(map, [key | rest]) when is_atom(key) and is_map(map) do
    cond do
      Map.has_key?(map, key) -> walk(Map.get(map, key), rest)
      Map.has_key?(map, Atom.to_string(key)) -> walk(Map.get(map, Atom.to_string(key)), rest)
      true -> false
    end
  end

  defp walk(list, [index | rest]) when is_integer(index) and index >= 0 and is_list(list) do
    case Enum.fetch(list, index) do
      {:ok, value} -> walk(value, rest)
      :error -> false
    end
  end

  defp walk(_value, _path), do: false

  @doc """
  Extracts the updates map from a post-validation changeset: exactly the
  castable fields the caller provided, with their casted values.

  Key selection is presence-in-raw-params intersected with the mode's
  castable fields (`fields/1`) — uniform for scalars and embeds. Omitted
  keys are absent (untouched on PATCH); explicit `null` is present as
  `nil` (clears); `[]` on an embed is present as `[]` (clears the array).
  Embed values are dumped to plain, atom-keyed maps (recursively,
  schema-driven; scalar structs like `Date` and `Decimal` stay intact),
  so the map feeds persistence changesets and JSON encoders directly.

  The result is uniformly atom-keyed at every level, and the atoms come
  from the schema definitions — never from client params (string keys in
  params are matched by presence, not converted), so the atom space stays
  closed regardless of input. `Ecto.Changeset.cast` accepts the map
  as-is; just don't merge string-keyed entries into it.

  Never use bare `apply_changes/1` output for persistence — it erases
  omitted-vs-provided. For `input: nil` actions this returns `%{}`.
  """
  @spec updates(Ecto.Changeset.t(), Context.t()) :: map()
  def updates(%Ecto.Changeset{data: %module{}} = changeset, %Context{} = ctx) do
    provided = module.fields(ctx.mode) |> Enum.filter(&provided?(ctx, &1))

    changeset
    |> Ecto.Changeset.apply_changes()
    |> dump(module)
    |> Map.take(provided)
  end

  def updates(%Ecto.Changeset{}, %Context{}), do: %{}

  # unwraps embed structs into plain maps, recursively; only fields the
  # schema declares as embeds are touched, so scalar structs (Date,
  # Decimal, ...) pass through intact
  defp dump(struct, module) do
    embeds = module.__schema__(:embeds)

    struct
    |> Map.from_struct()
    |> Map.new(fn {field, value} ->
      if field in embeds do
        {field, dump_embed(value, module.__schema__(:embed, field).related)}
      else
        {field, value}
      end
    end)
  end

  defp dump_embed(nil, _related), do: nil
  defp dump_embed(items, related) when is_list(items), do: Enum.map(items, &dump(&1, related))
  defp dump_embed(item, related), do: dump(item, related)

  ## Setup shared by run/3 and dry_run/3

  defp build(action, params, opts) do
    actor = fetch_actor!(opts)
    config = action.config()
    mode = fetch_mode!(action, config)

    case action.input() do
      nil -> :ok
      input -> Enact.Guardrails.ensure!(action, input, mode)
    end

    ctx = %Context{
      actor: actor,
      subject: nil,
      params: params,
      repo: fetch_repo!(opts),
      mode: mode,
      assigns: Keyword.get(opts, :assigns, %{})
    }

    {config, ctx}
  end

  defp pre_execute(action, config, ctx) do
    with :ok <- gate_anonymous(config, ctx.actor),
         {:ok, ctx} <- load_subject(action, config, ctx),
         changeset = cast(action, ctx),
         :ok <- authorize(action, ctx),
         {:ok, changeset} <- validate(action, changeset, ctx) do
      Enact.Resolve.run(action.resolvers(), changeset, ctx)
    end
  end

  defp check_digest(action, changeset, ctx, opts) do
    case Keyword.fetch(opts, :confirm_digest) do
      :error ->
        :ok

      {:ok, digest} ->
        if Preview.digest(action, ctx.mode, updates(changeset, ctx)) == digest do
          :ok
        else
          {:error, Error.conflict(:confirm_digest_mismatch)}
        end
    end
  end

  ## Option handling

  defp fetch_actor!(opts) do
    case Keyword.fetch(opts, :actor) do
      {:ok, nil} ->
        raise ArgumentError, """
        actor: nil is not a valid actor — nil is indistinguishable from a \
        forgotten actor. Anonymity must be an explicit value: pass :anonymous \
        (or a scope struct whose Enact.Actor impl returns true) for \
        unauthenticated callers, permitted by actions declaring anonymous?: true.\
        """

      {:ok, actor} ->
        actor

      :error ->
        raise ArgumentError,
              "the :actor option is required — every write must answer \"as whom?\""
    end
  end

  defp fetch_repo!(opts) do
    Keyword.get(opts, :repo) || Application.get_env(:enact, :repo) ||
      raise ArgumentError,
            "no repo configured — pass repo: MyApp.Repo or set `config :enact, repo: MyApp.Repo`"
  end

  defp fetch_mode!(action, config) do
    case Keyword.get(config, :mode, :create) do
      mode when mode in [:create, :patch] ->
        mode

      other ->
        raise ArgumentError,
              "#{inspect(action)}.config/0 returned mode: #{inspect(other)}; " <>
                "expected :create or :patch"
    end
  end

  ## Pipeline steps

  defp gate_anonymous(config, actor) do
    if Actor.anonymous?(actor) and not Keyword.get(config, :anonymous?, false) do
      {:error, Error.forbidden(:anonymous_actor)}
    else
      :ok
    end
  end

  defp load_subject(action, config, ctx) do
    if Keyword.get(config, :loads_subject?, false) do
      case action.load(ctx.params, ctx) do
        nil -> {:error, Error.not_found()}
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> {:error, Error.not_found(reason)}
        subject -> {:ok, %{ctx | subject: subject}}
      end
    else
      {:ok, ctx}
    end
  end

  defp cast(action, ctx) do
    case action.input() do
      nil -> Ecto.Changeset.change({%{}, %{}})
      module -> module.changeset(base(module, ctx), ctx.params, ctx.mode)
    end
  end

  defp base(module, %Context{mode: :create}), do: struct(module)

  defp base(module, %Context{mode: :patch, subject: nil}) do
    raise ArgumentError, """
    a patch-mode action with an input schema must load a subject: \
    #{inspect(module)}.from_subject/1 builds the validation base from it. \
    Set loads_subject?: true in config/0 and implement load/2.\
    """
  end

  defp base(module, %Context{mode: :patch, subject: subject}), do: module.from_subject(subject)

  defp authorize(action, ctx) do
    case action.authorize(ctx) do
      true ->
        :ok

      false ->
        {:error, Error.forbidden()}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.forbidden(reason)}

      other ->
        raise ArgumentError,
              "#{inspect(action)}.authorize/1 must return true, false, or " <>
                "{:error, reason}; got: #{inspect(other)}"
    end
  end

  defp validate(action, changeset, ctx) do
    changeset = if action.input(), do: action.validate(changeset, ctx), else: changeset

    if changeset.valid? do
      {:ok, changeset}
    else
      {:error, Error.invalid(changeset)}
    end
  end

  defp persist(action, changeset, ctx) do
    transaction_result =
      ctx.repo.transaction(fn ->
        case action.execute(changeset, ctx) do
          {:ok, result} -> result
          {:error, reason} -> ctx.repo.rollback(reason)
          other -> ctx.repo.rollback({:bad_execute_return, other})
        end
      end)

    case transaction_result do
      {:ok, result} -> {:ok, result}
      {:error, %Ecto.Changeset{} = failed} -> {:error, Error.invalid(failed)}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.internal(reason)}
    end
  end

  ## Telemetry

  defp emit({:ok, _result}, kind, action, ctx, start) do
    event =
      case kind do
        :run -> [:enact, :action, :success]
        :dry_run -> [:enact, :action, :dry_run]
      end

    :telemetry.execute(
      event,
      %{duration: System.monotonic_time() - start},
      %{action: action, mode: ctx.mode, actor: ctx.actor}
    )
  end

  defp emit({:error, %Error{type: type}}, kind, action, ctx, start) do
    event =
      case kind do
        :run -> [:enact, :action, :error]
        :dry_run -> [:enact, :action, :dry_run, :error]
      end

    :telemetry.execute(
      event,
      %{duration: System.monotonic_time() - start},
      %{action: action, mode: ctx.mode, actor: ctx.actor, type: type}
    )
  end
end
