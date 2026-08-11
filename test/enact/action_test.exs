defmodule Enact.ActionTest do
  use ExUnit.Case, async: true

  defmodule BareAction do
    use Enact.Action

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  defmodule CustomizedAction do
    use Enact.Action

    @impl Enact.Action
    def config, do: [mode: :patch, loads_subject?: true]

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def load(_params, _ctx), do: %{id: 1}

    @impl Enact.Action
    def authorize(_ctx), do: false

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  test "use Enact.Action provides overridable defaults" do
    ctx = %Enact.Context{actor: :anonymous, params: %{}}
    changeset = Ecto.Changeset.change({%{}, %{name: :string}})

    assert BareAction.config() == []
    assert BareAction.load(%{}, ctx) == nil
    assert BareAction.authorize(ctx) == true
    assert BareAction.validate(changeset, ctx) == changeset
    assert BareAction.resolvers() == []
    assert BareAction.after_commit(:result, ctx) == :ok
  end

  test "defaults are overridable" do
    ctx = %Enact.Context{actor: :anonymous, params: %{}}

    assert CustomizedAction.config() == [mode: :patch, loads_subject?: true]
    assert CustomizedAction.load(%{}, ctx) == %{id: 1}
    assert CustomizedAction.authorize(ctx) == false
  end

  test "actions implement the behaviour" do
    behaviours =
      BareAction.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    assert Enact.Action in behaviours
  end
end
