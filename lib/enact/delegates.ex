defmodule Enact.Delegates do
  @moduledoc """
  Opt-in helper that generates context one-liners for `Enact.run/3`,
  `Enact.dry_run/3`, `Enact.subject/3`, and `Enact.authorized/3`.

  Phoenix contexts remain the application API; this only writes the
  forwarding functions hosts otherwise type by hand. It is not an
  action-definition DSL — actions stay ordinary modules, and handwritten
  delegates remain valid.

      defmodule MyApp.Contacts do
        alias MyApp.Contacts.Actions.{CreateContact, UpdateContact}

        use Enact.Delegates, actions: [CreateContact, UpdateContact]

        # reads and load_subject fetchers stay here
      end

  For each action `MyApp.Contacts.Actions.CreateContact`, this defines:

      def create_contact(params, opts),
        do: Enact.run(CreateContact, params, opts)

      def create_contact_dry_run(params, opts),
        do: Enact.dry_run(CreateContact, params, opts)

      def create_contact_subject(params, opts),
        do: Enact.subject(CreateContact, params, opts)

      def create_contact_authorized(params, opts),
        do: Enact.authorized(CreateContact, params, opts)

  Names come from the last segment of the module, underscored via
  `Macro.underscore/1`. All four wrappers are generated for every listed
  action. Bodies only forward — no param reshaping, no persistable fields
  stamped in.

  If a host wants a different public name or a non-forwarding body, omit
  that module from the list and write the function by hand.
  """

  defmacro __using__(opts) do
    defs =
      opts
      |> fetch_actions!(__CALLER__)
      |> Enum.map(&delegate_defs/1)

    quote do
      (unquote_splicing(defs))
    end
  end

  defp fetch_actions!(opts, env) do
    opts = validate_opts!(opts)

    case Keyword.fetch(opts, :actions) do
      {:ok, actions} -> expand_actions!(actions, env)
      :error -> raise ArgumentError, expected_opts_message(opts)
    end
  end

  defp validate_opts!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, expected_opts_message(opts)
    end

    case Keyword.keys(opts) -- [:actions] do
      [] ->
        opts

      [key | _] ->
        raise ArgumentError, """
        use Enact.Delegates does not recognize option #{inspect(key)}.

        Recognized: :actions.
        """
    end
  end

  defp expand_actions!(actions, env) when is_list(actions) do
    if actions != [] and Keyword.keyword?(actions) do
      raise ArgumentError, expected_actions_message(actions)
    end

    expanded = Enum.map(actions, &expand_action!(&1, env))
    reject_duplicate_names!(expanded)
    expanded
  end

  defp expand_actions!(other, _env) do
    raise ArgumentError, expected_actions_message(other)
  end

  defp expand_action!(ast, env) do
    case Macro.expand(ast, env) do
      action when is_atom(action) and not is_nil(action) ->
        action

      _other ->
        raise ArgumentError, expected_actions_message(ast)
    end
  end

  defp reject_duplicate_names!(actions) do
    Enum.reduce(actions, %{}, fn action, acc ->
      name = function_name!(action)

      case acc do
        %{^name => other} ->
          raise ArgumentError, """
          Enact.Delegates cannot define #{name}/2 for both #{inspect(other)} \
          and #{inspect(action)} — function names come from the last module segment.

          Omit one from the list and write that delegate by hand if you need both.
          """

        _ ->
          Map.put(acc, name, action)
      end
    end)
  end

  defp delegate_defs(action) do
    name = function_name!(action)
    dry_name = :"#{name}_dry_run"
    subject_name = :"#{name}_subject"
    authorized_name = :"#{name}_authorized"
    run_doc = "Delegates to `Enact.run/3` with `#{inspect(action)}`."
    dry_doc = "Delegates to `Enact.dry_run/3` with `#{inspect(action)}`."
    subject_doc = "Delegates to `Enact.subject/3` with `#{inspect(action)}`."
    authorized_doc = "Delegates to `Enact.authorized/3` with `#{inspect(action)}`."

    quote do
      @doc unquote(run_doc)
      @spec unquote(name)(map(), keyword()) :: {:ok, term()} | {:error, Enact.Error.t()}
      def unquote(name)(params, opts), do: Enact.run(unquote(action), params, opts)

      @doc unquote(dry_doc)
      @spec unquote(dry_name)(map(), keyword()) ::
              {:ok, Enact.Preview.t()} | {:error, Enact.Error.t()}
      def unquote(dry_name)(params, opts), do: Enact.dry_run(unquote(action), params, opts)

      @doc unquote(subject_doc)
      @spec unquote(subject_name)(map(), keyword()) ::
              {:ok, struct()} | {:error, Enact.Error.t()}
      def unquote(subject_name)(params, opts), do: Enact.subject(unquote(action), params, opts)

      @doc unquote(authorized_doc)
      @spec unquote(authorized_name)(map(), keyword()) :: :ok | {:error, Enact.Error.t()}
      def unquote(authorized_name)(params, opts),
        do: Enact.authorized(unquote(action), params, opts)
    end
  end

  defp function_name!(action) when is_atom(action) do
    case Atom.to_string(action) do
      "Elixir." <> _ ->
        action
        |> Module.split()
        |> List.last()
        |> Macro.underscore()
        |> String.to_atom()

      _ ->
        raise ArgumentError, expected_actions_message(action)
    end
  end

  defp expected_opts_message(got) do
    """
    use Enact.Delegates expects options with an :actions key, got: #{Macro.to_string(got)}.

        use Enact.Delegates,
          actions: [
            MyApp.Contacts.Actions.CreateContact,
            MyApp.Contacts.Actions.UpdateContact
          ]

    Aliases work:

        alias MyApp.Contacts.Actions.{CreateContact, UpdateContact}
        use Enact.Delegates, actions: [CreateContact, UpdateContact]
    """
  end

  defp expected_actions_message(got) do
    """
    use Enact.Delegates :actions must be a list of action modules, got: #{Macro.to_string(got)}.

    Each entry must be an action module (an atom or alias).
    """
  end
end
