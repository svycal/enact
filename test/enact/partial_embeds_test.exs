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
    use Enact.EmbeddedInputSchema, partial: true

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
  end

  defmodule UpdatePref do
    use Enact.Action

    @impl Enact.Action
    def config, do: [mode: :patch]

    @impl Enact.Action
    def input, do: PrefInput

    @impl Enact.Action
    def load_subject(_params, _ctx), do: Process.get(:enact_subject)

    @impl Enact.Action
    def authorize(_ctx), do: true

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
    def authorize(_ctx), do: true

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

    test "an empty object is absent from updates" do
      assert {:ok, {updates, :not_merged}} = run(UpdatePref, %{"settings" => %{}})
      assert updates == %{}
    end

    test "an object with only undeclared keys is absent from updates" do
      assert {:ok, {updates, :not_merged}} =
               run(UpdatePref, %{"settings" => %{"allow_c" => false}})

      assert updates == %{}
    end

    test "undeclared keys alongside a provided sub-key keep the provided one" do
      assert {:ok, {updates, _merged}} =
               run(UpdatePref, %{"settings" => %{"allow_a" => nil, "allow_c" => false}})

      assert updates.settings == %{allow_a: nil}
    end

    test "an empty object stays provided for validate/2" do
      ctx = %Enact.Context{params: %{"settings" => %{}}}
      assert Enact.provided?(ctx, :settings)
    end

    test "applies on create too" do
      assert {:ok, updates} =
               run(CreatePref, %{"name" => "P", "settings" => %{"allow_a" => false}})

      assert updates.settings == %{allow_a: false}
    end

    defmodule WholesaleSettingsInput do
      use Ecto.Schema
      use Enact.EmbeddedInputSchema

      @primary_key false
      embedded_schema do
        field :allow_a, :boolean
        field :allow_b, :boolean
      end

      def changeset(item, params), do: cast_input(item, params, [:allow_a, :allow_b])
    end

    defmodule WholesalePrefInput do
      use Ecto.Schema
      use Enact.InputSchema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        embeds_one :settings, WholesaleSettingsInput
      end

      @impl Enact.InputSchema
      def changeset(base, params, _mode), do: base |> cast(params, []) |> cast_embed(:settings)

      @impl Enact.InputSchema
      def fields(_mode), do: [:settings]
    end

    test "an embed whose module is not partial keeps every key" do
      for params <- [%{"settings" => %{"allow_b" => false}}, %{"settings" => %{}}] do
        ctx = %Enact.Context{params: params, mode: :create}
        changeset = WholesalePrefInput.changeset(%WholesalePrefInput{}, params, :create)

        assert Enact.updates(changeset, ctx) ==
                 %{settings: %{allow_a: nil, allow_b: params["settings"]["allow_b"]}}
      end
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

    test "a preview whose only input is an empty object has no updates" do
      assert {:ok, %Preview{updates: updates}} =
               Enact.dry_run(UpdatePref, %{"settings" => %{}}, actor: :user, repo: FakeRepo)

      assert updates == %{}
    end

    test "the digest binds the partial object and round-trips through run" do
      params = %{"settings" => %{"allow_b" => false}}

      assert {:ok, preview} = Enact.dry_run(UpdatePref, params, actor: :user, repo: FakeRepo)

      assert {:ok, _} =
               run(UpdatePref, params, confirm_digest: preview.digest)
    end
  end

  describe "guardrails" do
    defmodule LegacyManifestInput do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        embeds_one :settings, SettingsInput
      end

      def changeset(base, params, _mode), do: cast_embed(cast(base, params, []), :settings)
      def fields(_mode), do: [:settings]
      def partial_embeds(_mode), do: [:settings]
    end

    test "a partial_embeds/1 export raises a teaching error" do
      assert_raise ArgumentError, ~r/exports partial_embeds\/1/, fn ->
        Enact.Guardrails.assert_valid_input_schema!(LegacyManifestInput, mode: :create)
      end
    end

    test "an unknown use option fails at compile time" do
      assert_raise ArgumentError, ~r/unknown keys \[:partal\]/, fn ->
        Code.compile_string("""
        defmodule Enact.PartialEmbedsTest.Misspelled do
          use Enact.EmbeddedInputSchema, partal: true
        end
        """)
      end
    end

    test "the :partial option accepts a compile-time expression" do
      [{module, _}] =
        Code.compile_string("""
        defmodule Enact.PartialEmbedsTest.FromAttribute do
          @flag true
          use Enact.EmbeddedInputSchema, partial: @flag
        end
        """)

      assert module.__enact__(:partial)
    end

    test "a non-boolean :partial fails at compile time" do
      assert_raise ArgumentError, ~r/expects :partial to be true or false/, fn ->
        Code.compile_string("""
        defmodule Enact.PartialEmbedsTest.NotBoolean do
          use Enact.EmbeddedInputSchema, partial: :yes
        end
        """)
      end
    end

    test "the conforming module passes" do
      assert Enact.Guardrails.assert_valid_input_schema!(PrefInput, mode: :patch) == :ok
    end
  end
end
