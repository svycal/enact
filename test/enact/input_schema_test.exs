defmodule Enact.InputSchemaTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset
  import Enact.InputSchema

  defmodule Input do
    use Ecto.Schema
    use Enact.InputSchema

    @primary_key false
    embedded_schema do
      field :name, :string
      field :summary, :string
      field :count, :integer
      field :active, :boolean
      field :status, Ecto.Enum, values: [:draft, :live]
    end

    @fields ~w(name summary count active status)a

    @impl Enact.InputSchema
    def changeset(base, params, :create) do
      cast_input(base, params, @fields, keep_empty_strings: [:summary])
    end

    @impl Enact.InputSchema
    def fields(:create), do: @fields
  end

  defp changeset(params), do: Input.changeset(%Input{}, params, :create)

  describe "cast_input/4" do
    test "empty strings on non-string fields are cast errors" do
      result = changeset(%{"count" => "", "active" => ""})

      assert {"is invalid", count_meta} = result.errors[:count]
      assert count_meta[:validation] == :cast
      assert {"is invalid", _meta} = result.errors[:active]
    end

    test "non-string coercions still apply" do
      result = changeset(%{"count" => "5", "active" => "true", "status" => "draft"})

      assert get_field(result, :count) == 5
      assert get_field(result, :active) == true
      assert get_field(result, :status) == :draft
    end

    test "empty strings on Ecto.Enum fields are rejected" do
      result = changeset(%{"status" => ""})

      assert {_message, meta} = result.errors[:status]
      assert meta[:validation] == :inclusion
    end

    test "non-empty string values pass through as sent (never trimmed)" do
      assert get_field(changeset(%{"name" => "  hi  "}), :name) == "  hi  "
    end

    test "empty-ish strings coalesce to nil (trimmed emptiness test)" do
      assert get_field(changeset(%{"name" => ""}), :name) == nil
      assert get_field(changeset(%{"name" => "   "}), :name) == nil
    end

    test "keep_empty_strings fields keep \"\" as the value" do
      assert get_field(changeset(%{"summary" => ""}), :summary) == ""
      assert get_field(changeset(%{"summary" => "   "}), :summary) == ""
      assert get_field(changeset(%{"summary" => " hi "}), :summary) == " hi "
    end

    test "explicit nil and omission pass through unchanged" do
      assert get_field(changeset(%{"name" => nil}), :name) == nil
      assert changeset(%{}).changes == %{}
    end

    test "atom-keyed params are normalized too" do
      assert get_field(changeset(%{name: "   "}), :name) == nil
      assert get_field(changeset(%{summary: ""}), :summary) == ""
    end

    test "composes onto an existing changeset" do
      result =
        %Input{}
        |> cast(%{"name" => "n"}, [:name])
        |> cast_input(%{"count" => "2"}, [:count])

      assert get_field(result, :name) == "n"
      assert get_field(result, :count) == 2
    end

    test "unknown options raise" do
      assert_raise ArgumentError, fn ->
        cast_input(%Input{}, %{}, [:name], trim: true)
      end
    end

    test "keep_empty_strings rejects non-string fields" do
      assert_raise ArgumentError, ~r/not a :string field/, fn ->
        cast_input(%Input{}, %{}, [:count], keep_empty_strings: [:count])
      end
    end

    test "option fields outside this head's cast list are inert" do
      # shared option attributes across mode heads with differing cast
      # lists: the listed field simply isn't cast by this head
      result = cast_input(%Input{}, %{"summary" => ""}, [:name], keep_empty_strings: [:summary])

      assert result.valid?
      assert result.changes == %{}
    end

    test "options reject nonexistent fields" do
      assert_raise ArgumentError, ~r/does not exist on/, fn ->
        cast_input(%Input{}, %{}, [:name], keep_empty_strings: [:typo_field])
      end
    end

    test "rejects non-schema arguments with a teaching error" do
      assert_raise ArgumentError, ~r/expects an input-schema struct or changeset/, fn ->
        cast_input(%{}, %{}, [:name])
      end

      assert_raise ArgumentError, ~r/is not one/, fn ->
        cast_input(~D[2026-01-01], %{}, [:name])
      end
    end

    test "rejects schemaless changesets with a teaching error" do
      schemaless = cast({%{}, %{name: :string}}, %{}, [:name])

      assert_raise ArgumentError, ~r/schemaless changesets are not supported/, fn ->
        cast_input(schemaless, %{}, [:name])
      end
    end
  end
end
