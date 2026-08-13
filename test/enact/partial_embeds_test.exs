defmodule Enact.PartialEmbedsTest do
  use ExUnit.Case, async: true

  alias Enact.Preview
  alias EnactTest.FakeRepo

  defmodule Settings do
    defstruct allow_a: true, allow_b: true
  end

  defmodule Pref do
    defstruct [:id, :name, :settings]
  end

  defmodule SettingsInput do
    use Ecto.Schema
    import Enact.InputSchema, only: [cast_input: 3]

    @primary_key false
    embedded_schema do
      field :allow_a, :boolean
      field :allow_b, :boolean
    end

    def changeset(item, params), do: cast_input(item, params, [:allow_a, :allow_b])
  end

  defmodule PrefInput do
    use Ecto.Schema
    use Enact.InputSchema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :name, :string
      embeds_one :settings, SettingsInput
    end

    @impl Enact.InputSchema
    def changeset(base, params, _mode) do
      base
      |> cast_input(params, [:name])
      |> cast_embed(:settings)
    end

    @impl Enact.InputSchema
    def fields(_mode), do: [:name, :settings]

    @impl Enact.InputSchema
    def from_subject(pref), do: %__MODULE__{name: pref.name}

    @impl Enact.InputSchema
    def partial_embeds(_mode), do: [:settings]
  end

  defmodule UpdatePref do
    use Enact.Action

    @impl Enact.Action
    def config, do: [mode: :patch, loads_subject?: true]

    @impl Enact.Action
    def input, do: PrefInput

    @impl Enact.Action
    def load(_params, _ctx), do: Process.get(:enact_subject)

    @impl Enact.Action
    def execute(changeset, ctx) do
      updates = Enact.updates(changeset, ctx)

      merged =
        case Map.fetch(updates, :settings) do
          # merged/4 IS the merge: one definition shared with validation
          {:ok, %{}} -> Enact.merged(changeset, ctx, :settings)
          _ -> :not_merged
        end

      {:ok, {updates, merged}}
    end
  end

  defmodule CreatePref do
    use Enact.Action

    @impl Enact.Action
    def input, do: PrefInput

    @impl Enact.Action
    def execute(changeset, ctx), do: {:ok, Enact.updates(changeset, ctx)}
  end

  defp run(action, params, opts \\ []) do
    Enact.run(action, params, Keyword.merge([actor: :user, repo: FakeRepo], opts))
  end

  setup do
    Process.put(:enact_subject, %Pref{
      id: 1,
      name: "Prefs",
      settings: %Settings{allow_a: true, allow_b: true}
    })

    :ok
  end

  describe "partial embed extraction" do
    test "updates carry only the provided sub-keys" do
      assert {:ok, {updates, merged}} =
               run(UpdatePref, %{"settings" => %{"allow_b" => false}})

      assert updates.settings == %{allow_b: false}
      assert merged == %{allow_a: true, allow_b: false}
    end

    test "an explicitly-null sub-key is present as nil (a clear)" do
      assert {:ok, {updates, merged}} =
               run(UpdatePref, %{"settings" => %{"allow_a" => nil, "allow_b" => false}})

      assert updates.settings == %{allow_a: nil, allow_b: false}
      assert merged == %{allow_a: nil, allow_b: false}
    end

    test "an omitted embed is absent from updates" do
      assert {:ok, {updates, :not_merged}} = run(UpdatePref, %{"name" => "New"})
      refute Map.has_key?(updates, :settings)
    end

    test "an explicit null clears the whole object" do
      assert {:ok, {updates, :not_merged}} = run(UpdatePref, %{"settings" => nil})
      assert updates.settings == nil
    end

    test "applies on create too" do
      assert {:ok, updates} =
               run(CreatePref, %{"name" => "P", "settings" => %{"allow_a" => false}})

      assert updates.settings == %{allow_a: false}
    end

    test "undeclared embeds keep wholesale semantics" do
      # ProjectInput has no partial_embeds/1 — its milestones dump with all
      # item fields, nils included (pinned by the existing suite)
      refute function_exported?(EnactTest.ProjectInput, :partial_embeds, 1)
    end
  end

  describe "previews and digests" do
    test "the preview shows exactly the provided sub-keys" do
      assert {:ok, %Preview{updates: updates}} =
               Enact.dry_run(UpdatePref, %{"settings" => %{"allow_b" => false}},
                 actor: :user,
                 repo: FakeRepo
               )

      assert updates.settings == %{allow_b: false}
    end

    test "the digest binds the partial object and round-trips through run" do
      params = %{"settings" => %{"allow_b" => false}}

      assert {:ok, preview} = Enact.dry_run(UpdatePref, params, actor: :user, repo: FakeRepo)

      assert {:ok, _} =
               run(UpdatePref, params, confirm_digest: preview.digest)
    end
  end

  describe "guardrails" do
    defmodule PartialManyInput do
      use Ecto.Schema
      use Enact.InputSchema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        embeds_many :items, SettingsInput
      end

      @impl Enact.InputSchema
      def changeset(base, params, _mode), do: cast_embed(cast(base, params, []), :items)

      @impl Enact.InputSchema
      def fields(_mode), do: [:items]

      @impl Enact.InputSchema
      def partial_embeds(_mode), do: [:items]
    end

    defmodule PartialTypoInput do
      use Ecto.Schema
      use Enact.InputSchema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field :name, :string
      end

      @impl Enact.InputSchema
      def changeset(base, params, _mode), do: cast(base, params, [:name])

      @impl Enact.InputSchema
      def fields(_mode), do: [:name]

      @impl Enact.InputSchema
      def partial_embeds(_mode), do: [:settings]
    end

    test "declaring an embeds_many raises a teaching error" do
      assert_raise ArgumentError, ~r/which is an embeds_many/, fn ->
        Enact.Guardrails.assert_valid_input_schema!(PartialManyInput, mode: :create)
      end
    end

    test "declaring a non-embed raises a teaching error" do
      assert_raise ArgumentError, ~r/not an embed on the schema/, fn ->
        Enact.Guardrails.assert_valid_input_schema!(PartialTypoInput, mode: :create)
      end
    end

    test "the conforming module passes" do
      assert Enact.Guardrails.assert_valid_input_schema!(PrefInput, mode: :patch) == :ok
    end
  end
end
