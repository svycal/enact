defmodule Enact.GuardrailsTest do
  use ExUnit.Case, async: true

  import Enact.Guardrails

  alias EnactTest.FakeRepo

  ## Offending fixture schemas

  defmodule DefaultField do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :status, :string, default: "draft"
    end
  end

  defmodule FalseDefault do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :flag, :boolean, default: false
    end
  end

  defmodule WithPK do
    use Ecto.Schema

    # no @primary_key false — embedded_schema defaults to a binary_id PK
    embedded_schema do
      field :name, :string
    end
  end

  defmodule NestedPKParent do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      embeds_many :items, WithPK
    end

    def changeset(base, params, _mode), do: Ecto.Changeset.cast(base, params, [])
    def fields(_mode), do: [:items]
  end

  defmodule WithAssoc do
    use Ecto.Schema

    @primary_key false
    schema "with_assoc" do
      field :name, :string
      has_many :items, EnactTest.MilestoneInput, references: :name, foreign_key: :title
    end
  end

  defmodule NoFieldsExport do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :name, :string
    end

    def changeset(base, params, _mode), do: Ecto.Changeset.cast(base, params, [:name])
  end

  defmodule CreateOnly do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :name, :string
    end

    def changeset(base, params, _mode), do: Ecto.Changeset.cast(base, params, [:name])
    def fields(_mode), do: [:name]
  end

  defmodule SelfRef do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :name, :string
      embeds_many :children, __MODULE__
    end

    def changeset(base, params, _mode), do: Ecto.Changeset.cast(base, params, [:name])
    def fields(_mode), do: [:name, :children]
  end

  describe "assert_valid_input_schema!/2" do
    test "a conforming module passes in both modes" do
      assert assert_valid_input_schema!(EnactTest.ProjectInput, mode: :create) == :ok
      assert assert_valid_input_schema!(EnactTest.ProjectInput, mode: :patch) == :ok
    end

    test "a scalar field default raises" do
      assert_raise ArgumentError, ~r/declares a default for field :status/, fn ->
        assert_valid_input_schema!(DefaultField)
      end
    end

    test "a falsy default raises (default: false is still a default)" do
      assert_raise ArgumentError, ~r/declares a default for field :flag/, fn ->
        assert_valid_input_schema!(FalseDefault)
      end
    end

    test "a primary key raises" do
      assert_raise ArgumentError, ~r/declares a primary key/, fn ->
        assert_valid_input_schema!(WithPK)
      end
    end

    test "a nested primary key raises, naming the nested module" do
      assert_raise ArgumentError, ~r/WithPK.*declares a primary key/s, fn ->
        assert_valid_input_schema!(NestedPKParent)
      end
    end

    test "associations raise" do
      assert_raise ArgumentError, ~r/declares associations/, fn ->
        assert_valid_input_schema!(WithAssoc)
      end
    end

    test "a missing changeset/3 export raises" do
      assert_raise ArgumentError, ~r/does not export changeset\/3/, fn ->
        assert_valid_input_schema!(EnactTest.MilestoneInput)
      end
    end

    test "a missing fields/1 export raises" do
      assert_raise ArgumentError, ~r/does not export fields\/1/, fn ->
        assert_valid_input_schema!(NoFieldsExport)
      end
    end

    test "from_subject/1 is required only for patch-mode use" do
      assert assert_valid_input_schema!(CreateOnly, mode: :create) == :ok
      assert assert_valid_input_schema!(CreateOnly) == :ok

      assert_raise ArgumentError, ~r/does not export from_subject\/1/, fn ->
        assert_valid_input_schema!(CreateOnly, mode: :patch)
      end
    end

    test "self-referential embeds terminate via the cycle guard" do
      assert assert_valid_input_schema!(SelfRef, mode: :create) == :ok
    end

    test "a non-schema module raises" do
      assert_raise ArgumentError, ~r/not an Ecto embedded schema/, fn ->
        assert_valid_input_schema!(String)
      end
    end
  end

  describe "runner integration" do
    defmodule BadInputAction do
      use Enact.Action

      @impl Enact.Action
      def input, do: Enact.GuardrailsTest.DefaultField

      @impl Enact.Action
      def authorize(_ctx), do: true

      @impl Enact.Action
      def execute(_changeset, _ctx), do: {:ok, :done}
    end

    test "the runner checks the input schema on first run" do
      assert_raise ArgumentError, ~r/declares a default/, fn ->
        Enact.run(BadInputAction, %{}, actor: :user, repo: FakeRepo)
      end
    end

    test "valid schemas are memoized after first run" do
      assert {:ok, _} =
               Enact.run(EnactTest.CreateProject, %{"name" => "A", "slug" => "a"},
                 actor: :user,
                 repo: FakeRepo
               )

      assert :persistent_term.get({Enact.Guardrails, EnactTest.CreateProject}, false)
    end
  end
end
