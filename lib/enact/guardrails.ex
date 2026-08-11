defmodule Enact.Guardrails do
  @moduledoc """
  Mechanical enforcement of input-schema invariants — every "just don't
  do X" rule that is detectable gets detected and raised, upgrading
  conventions to invariants.

  The runner invokes `assert_valid_input_schema!/2` automatically on an
  action's first run (memoized per action). Host apps should *also* call
  it from a CI test on every action's input module for compile-adjacent
  feedback:

      for action <- MyApp.Actions.all(), input = action.input() do
        Enact.Guardrails.assert_valid_input_schema!(input,
          mode: Keyword.get(action.config(), :mode, :create)
        )
      end
  """

  @doc false
  def ensure!(action, input_module, mode) do
    key = {__MODULE__, action}

    unless :persistent_term.get(key, false) do
      assert_valid_input_schema!(input_module, mode: mode)
      :persistent_term.put(key, true)
    end

    :ok
  end

  @doc """
  Walks an input module recursively (through its embeds, with a cycle
  guard for self-referential schemas) and raises a teaching error on:

  1. any scalar field with a non-nil default (embed fields excluded —
     their structural `[]`/`nil` defaults are fine)
  2. a primary key at any level
  3. associations at any level — embeds only
  4. top-level module only: missing `changeset/3` or `fields/1` exports,
     or missing `from_subject/1` when `mode: :patch` is given (nested item
     modules are exempt — they implement `changeset/2` for `cast_embed`)

  Options: `:mode` — the referencing action's mode; `:patch` requires
  `from_subject/1`.
  """
  def assert_valid_input_schema!(module, opts \\ []) do
    ensure_schema!(module)
    walk(module, MapSet.new())
    check_contract!(module, Keyword.get(opts, :mode))
    :ok
  end

  defp walk(module, visited) do
    if MapSet.member?(visited, module) do
      visited
    else
      check_schema!(module)

      Enum.reduce(module.__schema__(:embeds), MapSet.put(visited, module), fn name, visited ->
        related = module.__schema__(:embed, name).related
        ensure_schema!(related)
        walk(related, visited)
      end)
    end
  end

  defp ensure_schema!(module) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) do
      raise ArgumentError, """
      #{inspect(module)} is not an Ecto embedded schema.

      Input modules are plain `use Ecto.Schema` + `embedded_schema` modules \
      implementing the Enact.InputSchema behaviour — see the Enact.InputSchema docs.\
      """
    end
  end

  defp check_schema!(module) do
    embeds = module.__schema__(:embeds)
    defaults = struct(module)

    # Enum.each, not a `for` with a `default = ...` binding: a bare binding in
    # a comprehension acts as a filter, which silently skips falsy defaults
    # (`default: false` — the most common Ecto default in the wild)
    Enum.each(module.__schema__(:fields) -- embeds, fn field ->
      default = Map.get(defaults, field)

      unless is_nil(default) do
        raise ArgumentError, """
        input schema #{inspect(module)} declares a default for field #{inspect(field)} \
        (#{inspect(default)}).

        Input schemas must not declare field defaults: omitted fields are excluded \
        from extraction by presence, so a schema default never persists — it only \
        misleads validations into seeing a value the write will not contain. Put \
        the default on the DB column (preferred) or the persistence schema instead.\
        """
      end
    end)

    if module.__schema__(:primary_key) != [] do
      raise ArgumentError, """
      input schema #{inspect(module)} declares a primary key \
      (#{inspect(module.__schema__(:primary_key))}).

      Add `@primary_key false` (at every nesting level): item IDs cause \
      cast_embed to switch to diff-by-id semantics, silently breaking \
      replace-wholesale PATCH arrays.\
      """
    end

    if module.__schema__(:associations) != [] do
      raise ArgumentError, """
      input schema #{inspect(module)} declares associations \
      (#{inspect(module.__schema__(:associations))}).

      Input schemas are embeds only — an association here means the \
      input/persistence boundary is being blurred. Reference other records \
      by public id and resolve them via resolvers/0 instead.\
      """
    end
  end

  defp check_contract!(module, mode) do
    unless function_exported?(module, :changeset, 3) do
      raise ArgumentError, """
      input schema #{inspect(module)} does not export changeset/3.

      Top-level input modules implement the Enact.InputSchema behaviour: \
      `changeset(base, params, mode)` with one head per mode. (Nested item \
      schemas implement changeset/2 for cast_embed and are exempt.) See the \
      Enact.InputSchema docs.\
      """
    end

    unless function_exported?(module, :fields, 1) do
      raise ArgumentError, """
      input schema #{inspect(module)} does not export fields/1.

      `fields(mode)` is the introspection surface for mode-specific castable \
      fields — Enact.updates/2 key selection and host-app reconciliation tests \
      read it. Include embed names, not just scalars. See the Enact.InputSchema \
      docs.\
      """
    end

    if mode == :patch and not function_exported?(module, :from_subject, 1) do
      raise ArgumentError, """
      input schema #{inspect(module)} is used by a patch-mode action but does \
      not export from_subject/1.

      Patch mode builds the validation base from the loaded subject: \
      `from_subject/1` is an explicit, total projection of the subject into \
      the input representation (embeds never seeded). See the Enact.InputSchema \
      docs.\
      """
    end
  end
end
