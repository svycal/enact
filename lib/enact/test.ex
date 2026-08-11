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
