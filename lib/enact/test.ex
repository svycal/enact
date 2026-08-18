defmodule Enact.Test do
  @moduledoc """
  Shared test helpers for host-app action tests (and Enact's own suite).

      import Enact.Test

      test "rejects a blank name" do
        {:error, _} = result = Enact.run(CreateProject, %{"name" => ""}, actor: actor)
        assert_invalid(result, on: :name)
      end

  Intended for the test environment; the assertions require ExUnit.
  """

  @doc """
  Asserts the result is `{:error, %Enact.Error{type: :invalid}}`, and —
  given `on: field` — that the changeset carries an error on that
  top-level field. Returns the changeset for further assertions.
  """
  @spec assert_invalid(term(), keyword()) :: Ecto.Changeset.t()
  def assert_invalid(result, opts \\ [])

  def assert_invalid({:error, %Enact.Error{type: :invalid, changeset: changeset}}, opts) do
    case Keyword.fetch(opts, :on) do
      {:ok, field} ->
        unless Keyword.has_key?(changeset.errors, field) do
          raise ExUnit.AssertionError,
            message:
              "expected an error on #{inspect(field)}, but the changeset has errors on: " <>
                inspect(Enum.uniq(Keyword.keys(changeset.errors)))
        end

      :error ->
        :ok
    end

    changeset
  end

  def assert_invalid(other, _opts) do
    raise ExUnit.AssertionError,
      message: "expected {:error, %Enact.Error{type: :invalid}}, got: #{inspect(other)}"
  end

  @doc """
  Builds an `Enact.Context` for unit-testing `validate/2` callbacks or
  fetchers directly, without running the pipeline.

  Options (all optional): `:actor` (default `:test_actor`), `:subject`,
  `:params` (default `%{}`), `:repo`, `:mode` (default `:create`),
  `:assigns` (default `%{}`).

  `:params` are stored as given — this helper does not stringify keys.
  `Enact.run/3` / `dry_run/3` do. Pass string keys here if the code
  under test pattern-matches on them.
  """
  @spec build_ctx(keyword()) :: Enact.Context.t()
  def build_ctx(opts \\ []) do
    %Enact.Context{
      actor: Keyword.get(opts, :actor, :test_actor),
      subject: Keyword.get(opts, :subject),
      params: Keyword.get(opts, :params, %{}),
      repo: Keyword.get(opts, :repo),
      mode: Keyword.get(opts, :mode, :create),
      assigns: Keyword.get(opts, :assigns, %{})
    }
  end

  @doc """
  Asserts that an input module rejects `""` on every non-string castable
  field for the given mode.

  Ecto's default cast silently coerces `""` to `nil` on any field type.
  For non-string fields that turns malformed input into a null-clear
  instruction instead of a cast error. This probe calls
  `module.changeset/3` with `""` for each non-string scalar field in
  `fields(mode)` and fails unless the field carries a cast error —
  regardless of whether the module uses `Enact.InputSchema.cast_input/4`
  or a stock `cast` with `empty_values: []`.

  Probing is safe because input modules are dependency-free by contract
  (no ctx, no repo). Errors on other fields (for example
  `validate_required`) are ignored; only the probed field's cast outcome
  is checked. `:string`, `:binary`, and `:binary_id` fields are skipped:
  `""` is a valid value for the first two, and `:binary_id`'s
  changeset-level cast accepts any binary (its format is validated at dump
  time). A rejection counts when the probed field carries any error other
  than `validation: :required` — custom types may tag rejections with
  their own metadata (`Ecto.Enum` uses `:inclusion`), while a `:required`
  error is the footgun's own signature: `""` silently coerced to `nil`,
  then caught downstream.

  Coverage is top-level only: item schemas have no `fields/1` manifest,
  so their cast lists are not introspectable. Item-level strictness is a
  convention — cast item fields with `cast_input/4` — rather than a
  probed guarantee.

  Options: `:except` — fields whose custom types accept `""` deliberately.
  """
  @spec assert_rejects_empty_strings(module(), atom(), keyword()) :: :ok
  def assert_rejects_empty_strings(module, mode, opts \\ []) do
    except = Keyword.get(opts, :except, [])
    embeds = module.__schema__(:embeds)

    for field <- module.fields(mode) -- embeds,
        field not in except,
        module.__schema__(:type, field) not in [:string, :binary, :binary_id] do
      changeset = module.changeset(struct(module), %{Atom.to_string(field) => ""}, mode)

      rejected? =
        changeset.errors
        |> Keyword.get_values(field)
        |> Enum.any?(fn {_message, meta} -> meta[:validation] != :required end)

      unless rejected? do
        raise ExUnit.AssertionError,
          message:
            "#{inspect(module)} silently coerced \"\" on #{inspect(field)} " <>
              "(#{inspect(mode)}) — cast non-string fields with " <>
              "Enact.InputSchema.cast_input/4 or empty_values: []"
      end
    end

    :ok
  end

  @doc """
  Flattens a changeset's errors into a map of field → messages, with
  nested embed errors as per-index lists of maps — the conventional
  `errors_on` helper, shipped so host apps don't reinvent it.

      assert %{milestones: [%{}, %{owner_id: ["not found"]}]} = errors_on(changeset)
  """
  @spec errors_on(Ecto.Changeset.t()) :: map()
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
