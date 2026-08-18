defmodule Enact.ResolveTest do
  use ExUnit.Case, async: true

  import Enact.Test, only: [errors_on: 1]

  alias Enact.Error
  alias EnactTest.{FakeRepo, Project}

  @valid %{"name" => "Alpha", "slug" => "alpha"}

  defp run(action, params, opts \\ []) do
    Enact.run(action, params, Keyword.merge([actor: :user, repo: FakeRepo], opts))
  end

  defmodule Refs do
    def fetch_owner(public_id, _ctx) do
      send(self(), {:fetch_owner, public_id})

      case public_id do
        "usr_ok" -> {:ok, %{id: 42, name: "Jane"}}
        "usr_deactivated" -> {:error, "has been deactivated"}
        _ -> :error
      end
    end

    def fetch_milestone_owners(public_ids, _ctx) do
      send(self(), {:fetch_milestone_owners, public_ids})

      public_ids
      |> Enum.flat_map(fn
        "usr_ok" -> [{"usr_ok", %{id: 42}}]
        "usr_2" -> [{"usr_2", %{id: 43}}]
        "usr_deactivated" -> [{"usr_deactivated", {:error, "has been deactivated"}}]
        _absent -> []
      end)
      |> Map.new()
    end
  end

  defmodule CreateWithRefs do
    use Enact.Action

    @impl Enact.Action
    def input, do: EnactTest.ProjectInput

    @impl Enact.Action
    def resolvers do
      [
        owner: {:owner_id, &Refs.fetch_owner/2},
        milestone_owners: {[:milestones, :owner_id], &Refs.fetch_milestone_owners/2}
      ]
    end

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(changeset, ctx), do: {:ok, {Enact.updates(changeset, ctx), ctx.assigns}}
  end

  defmodule UpdateWithRefs do
    use Enact.Action

    @impl Enact.Action
    def config, do: [mode: :patch]

    @impl Enact.Action
    def input, do: EnactTest.ProjectInput

    @impl Enact.Action
    def load_subject(_params, _ctx), do: Process.get(:enact_subject)

    @impl Enact.Action
    def resolvers, do: [owner: {:owner_id, &Refs.fetch_owner/2}]

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(changeset, ctx), do: {:ok, {Enact.updates(changeset, ctx), ctx.assigns}}
  end

  describe "scalar resolution" do
    test "success stashes the record in assigns under the resolver name" do
      params = Map.put(@valid, "owner_id", "usr_ok")

      assert {:ok, {updates, assigns}} = run(CreateWithRefs, params)
      assert updates.owner_id == "usr_ok"
      assert assigns.owner == %{id: 42, name: "Jane"}
    end

    test "an unknown id produces the generic field error tagged :resolution" do
      params = Map.put(@valid, "owner_id", "usr_missing")

      assert {:error, %Error{type: :invalid, changeset: changeset}} =
               run(CreateWithRefs, params)

      assert %{owner_id: ["not found"]} = errors_on(changeset)
      assert {"not found", meta} = changeset.errors[:owner_id]
      assert meta[:validation] == :resolution
    end

    test "{:error, message} renders a precise message on the same field" do
      params = Map.put(@valid, "owner_id", "usr_deactivated")

      assert {:error, %Error{type: :invalid, changeset: changeset}} =
               run(CreateWithRefs, params)

      assert %{owner_id: ["has been deactivated"]} = errors_on(changeset)
    end

    test "an unprovided reference never calls the fetcher" do
      assert {:ok, {_updates, assigns}} = run(CreateWithRefs, @valid)

      refute_received {:fetch_owner, _}
      refute Map.has_key?(assigns, :owner)
    end

    test "resolver-stashed assigns win over the assigns: passthrough" do
      params = Map.put(@valid, "owner_id", "usr_ok")

      assert {:ok, {_updates, assigns}} =
               run(CreateWithRefs, params, assigns: %{owner: :stale, ip: "1.2.3.4"})

      assert assigns.owner == %{id: 42, name: "Jane"}
      assert assigns.ip == "1.2.3.4"
    end
  end

  describe "scalar resolution on patch" do
    setup do
      Process.put(:enact_subject, %Project{
        id: 1,
        name: "Old",
        slug: "old",
        owner_id: "usr_old"
      })

      :ok
    end

    test "an untouched reference survives without resolving" do
      assert {:ok, {updates, assigns}} = run(UpdateWithRefs, %{"name" => "New"})

      assert updates == %{name: "New"}
      refute_received {:fetch_owner, _}
      refute Map.has_key?(assigns, :owner)
    end

    test "a changed reference re-resolves" do
      assert {:ok, {updates, assigns}} = run(UpdateWithRefs, %{"owner_id" => "usr_ok"})

      assert updates == %{owner_id: "usr_ok"}
      assert_received {:fetch_owner, "usr_ok"}
      assert assigns.owner == %{id: 42, name: "Jane"}
    end

    test "a provided-identical reference still re-resolves (assigns contract stays total)" do
      Process.put(:enact_subject, %Project{id: 1, name: "Old", slug: "old", owner_id: "usr_ok"})

      # re-sending the current value records no changeset change, but it is
      # a provided write: it lands in updates, so execute must find assigns.owner
      assert {:ok, {updates, assigns}} = run(UpdateWithRefs, %{"owner_id" => "usr_ok"})

      assert updates == %{owner_id: "usr_ok"}
      assert_received {:fetch_owner, "usr_ok"}
      assert assigns.owner == %{id: 42, name: "Jane"}
    end

    test "an explicit nil-clear resolves nothing and flows to updates" do
      assert {:ok, {updates, assigns}} = run(UpdateWithRefs, %{"owner_id" => nil})

      assert updates == %{owner_id: nil}
      refute_received {:fetch_owner, _}
      refute Map.has_key?(assigns, :owner)
    end
  end

  describe "batch resolution" do
    test "collects unique non-nil ids into one fetcher call and stashes the lookup map" do
      params =
        Map.put(@valid, "milestones", [
          %{"title" => "a", "owner_id" => "usr_ok"},
          %{"title" => "b", "owner_id" => "usr_2"},
          %{"title" => "c", "owner_id" => "usr_ok"},
          %{"title" => "d"}
        ])

      assert {:ok, {updates, assigns}} = run(CreateWithRefs, params)

      assert_received {:fetch_milestone_owners, ["usr_ok", "usr_2"]}
      assert assigns.milestone_owners == %{"usr_ok" => %{id: 42}, "usr_2" => %{id: 43}}
      assert length(updates.milestones) == 4
    end

    test "absent and precise errors land on the right items at the right indices" do
      params =
        Map.put(@valid, "milestones", [
          %{"title" => "a", "owner_id" => "usr_ok"},
          %{"title" => "b", "owner_id" => "usr_missing"},
          %{"title" => "c", "owner_id" => "usr_deactivated"}
        ])

      assert {:error, %Error{type: :invalid, changeset: changeset}} =
               run(CreateWithRefs, params)

      assert %{
               milestones: [
                 %{},
                 %{owner_id: ["not found"]},
                 %{owner_id: ["has been deactivated"]}
               ]
             } = errors_on(changeset)
    end

    test "all-nil item ids skip the fetcher call entirely" do
      params = Map.put(@valid, "milestones", [%{"title" => "a"}, %{"title" => "b"}])

      assert {:ok, {_updates, assigns}} = run(CreateWithRefs, params)

      refute_received {:fetch_milestone_owners, _}
      refute Map.has_key?(assigns, :milestone_owners)
    end

    test "an omitted embed skips the fetcher call" do
      assert {:ok, _} = run(CreateWithRefs, @valid)
      refute_received {:fetch_milestone_owners, _}
    end

    test "scalar and batch failures are collected in one response" do
      params =
        @valid
        |> Map.put("owner_id", "usr_missing")
        |> Map.put("milestones", [%{"title" => "a", "owner_id" => "usr_missing"}])

      assert {:error, %Error{type: :invalid, changeset: changeset}} =
               run(CreateWithRefs, params)

      assert %{
               owner_id: ["not found"],
               milestones: [%{owner_id: ["not found"]}]
             } = errors_on(changeset)
    end
  end

  describe "ordering" do
    test "garbage input never triggers reference loads (validate gates resolve)" do
      params = %{"owner_id" => "usr_ok"}

      assert {:error, %Error{type: :invalid}} = run(CreateWithRefs, params)
      refute_received {:fetch_owner, _}
    end
  end

  describe "spec validation" do
    defmodule SettingsInput do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field :owner_id, :string
      end

      def changeset(item, params), do: cast(item, params, [:owner_id])
    end

    defmodule OneEmbedInput do
      use Ecto.Schema
      import Ecto.Changeset

      @behaviour Enact.InputSchema

      @primary_key false
      embedded_schema do
        field :name, :string
        embeds_one :settings, SettingsInput
      end

      @impl Enact.InputSchema
      def changeset(base, params, _mode) do
        base |> cast(params, [:name]) |> cast_embed(:settings)
      end

      @impl Enact.InputSchema
      def fields(_mode), do: [:name, :settings]
    end

    defmodule PathOnEmbedsOne do
      use Enact.Action

      @impl Enact.Action
      def input, do: OneEmbedInput

      @impl Enact.Action
      def resolvers, do: [owner: {[:settings, :owner_id], &__MODULE__.noop/2}]

      @impl Enact.Action
      def authorize(_ctx), do: true

      @impl Enact.Action
      def execute(_changeset, _ctx), do: {:ok, :done}

      def noop(_ids, _ctx), do: %{}
    end

    defmodule PathOnScalar do
      use Enact.Action

      @impl Enact.Action
      def input, do: EnactTest.ProjectInput

      @impl Enact.Action
      def resolvers, do: [owner: {[:name, :owner_id], &__MODULE__.noop/2}]

      @impl Enact.Action
      def authorize(_ctx), do: true

      @impl Enact.Action
      def execute(_changeset, _ctx), do: {:ok, :done}

      def noop(_ids, _ctx), do: %{}
    end

    defmodule ListReturningBatch do
      use Enact.Action

      @impl Enact.Action
      def input, do: EnactTest.ProjectInput

      @impl Enact.Action
      def resolvers, do: [milestone_owners: {[:milestones, :owner_id], &__MODULE__.bad/2}]

      @impl Enact.Action
      def authorize(_ctx), do: true

      @impl Enact.Action
      def execute(_changeset, _ctx), do: {:ok, :done}

      def bad(ids, _ctx), do: Enum.map(ids, &{&1, %{}})
    end

    defmodule DeepPathAction do
      use Enact.Action

      @impl Enact.Action
      def input, do: EnactTest.ProjectInput

      @impl Enact.Action
      def resolvers, do: [deep: {[:milestones, :owner, :id], &__MODULE__.noop/2}]

      @impl Enact.Action
      def authorize(_ctx), do: true

      @impl Enact.Action
      def execute(_changeset, _ctx), do: {:ok, :done}

      def noop(_ids, _ctx), do: %{}
    end

    defmodule TypoFieldAction do
      use Enact.Action

      @impl Enact.Action
      def input, do: EnactTest.ProjectInput

      @impl Enact.Action
      def resolvers, do: [owner: {:oops_id, &Refs.fetch_owner/2}]

      @impl Enact.Action
      def authorize(_ctx), do: true

      @impl Enact.Action
      def execute(_changeset, _ctx), do: {:ok, :done}
    end

    test "a path over an embeds_one raises a teaching error" do
      assert_raise ArgumentError, ~r/not an embeds_many/, fn ->
        run(PathOnEmbedsOne, %{"name" => "x"})
      end
    end

    test "a path headed by a scalar field raises a teaching error" do
      assert_raise ArgumentError, ~r/not an embeds_many/, fn ->
        run(PathOnScalar, @valid)
      end
    end

    test "a batch fetcher returning a non-map raises a teaching error" do
      params = Map.put(@valid, "milestones", [%{"title" => "a", "owner_id" => "usr_ok"}])

      assert_raise ArgumentError, ~r/must return a map/, fn ->
        run(ListReturningBatch, params)
      end
    end

    test "paths deeper than one level raise a teaching error" do
      assert_raise ArgumentError, ~r/one level deep/, fn ->
        run(DeepPathAction, @valid)
      end
    end

    test "a resolver field missing from the input schema raises a teaching error" do
      assert_raise ArgumentError, ~r/does not exist on EnactTest.ProjectInput/, fn ->
        run(TypoFieldAction, @valid)
      end
    end

    test "a malformed fetcher return raises a teaching error" do
      defmodule BadFetcherAction do
        use Enact.Action

        @impl Enact.Action
        def input, do: EnactTest.ProjectInput

        @impl Enact.Action
        def resolvers, do: [owner: {:owner_id, fn _id, _ctx -> :nope end}]

        @impl Enact.Action
        def authorize(_ctx), do: true

        @impl Enact.Action
        def execute(_changeset, _ctx), do: {:ok, :done}
      end

      assert_raise ArgumentError, ~r/must return/, fn ->
        run(BadFetcherAction, Map.put(@valid, "owner_id", "usr_ok"))
      end
    end
  end
end
