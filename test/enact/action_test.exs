defmodule Enact.ActionTest do
  use ExUnit.Case, async: true

  defmodule BareAction do
    use Enact.Action

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  defmodule CustomizedAction do
    use Enact.Action

    @impl Enact.Action
    def config, do: [mode: :patch]

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def load_subject(_params, _ctx), do: %{id: 1}

    @impl Enact.Action
    def authorize(_ctx), do: false

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  test "use Enact.Action provides overridable defaults" do
    ctx = %Enact.Context{actor: :anonymous, params: %{}}
    changeset = Ecto.Changeset.change({%{}, %{name: :string}})

    assert BareAction.config() == []
    assert BareAction.load_subject(%{}, ctx) == :no_subject
    assert BareAction.validate(changeset, ctx) == changeset
    assert BareAction.resolvers() == []
    assert BareAction.after_commit(:result, ctx) == :ok
  end

  test "optional callbacks are declared; authorize/1 is required" do
    optional = Enact.Action.behaviour_info(:optional_callbacks)

    assert {:config, 0} in optional
    assert {:load_subject, 2} in optional
    assert {:validate, 2} in optional
    assert {:resolvers, 0} in optional
    assert {:after_commit, 2} in optional

    refute {:authorize, 1} in optional
    refute {:input, 0} in optional
    refute {:execute, 2} in optional
  end

  test "defaults are overridable" do
    ctx = %Enact.Context{actor: :anonymous, params: %{}}

    assert CustomizedAction.config() == [mode: :patch]
    assert CustomizedAction.load_subject(%{}, ctx) == %{id: 1}
    assert CustomizedAction.authorize(ctx) == false
  end

  test "actions implement the behaviour" do
    behaviours =
      BareAction.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    assert Enact.Action in behaviours
  end
end
