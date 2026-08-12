defmodule Enact.TestTest do
  use ExUnit.Case, async: true

  import Enact.Test

  alias EnactTest.{CreateProject, FakeRepo}

  defp invalid_result do
    Enact.run(CreateProject, %{"priority" => -1}, actor: :user, repo: FakeRepo)
  end

  describe "assert_invalid/2" do
    test "passes on an :invalid result and returns the changeset" do
      assert %Ecto.Changeset{} = assert_invalid(invalid_result())
    end

    test "checks the named field" do
      assert_invalid(invalid_result(), on: :name)
      assert_invalid(invalid_result(), on: :priority)
    end

    test "fails when the field has no error" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_invalid(invalid_result(), on: :owner_id)
        end

      assert error.message =~ "expected an error on :owner_id"
    end

    test "fails on non-invalid results" do
      assert_raise ExUnit.AssertionError, fn -> assert_invalid({:ok, :done}) end

      assert_raise ExUnit.AssertionError, fn ->
        assert_invalid({:error, Enact.Error.forbidden()})
      end
    end
  end

  describe "assert_rejects_empty_strings/3" do
    defmodule LooseInput do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field :count, :integer
      end

      # stock cast: "" silently coerces to nil
      def changeset(base, params, :create), do: cast(base, params, [:count])
      def fields(:create), do: [:count]
    end

    test "passes for modules that reject empty strings on non-string fields" do
      assert assert_rejects_empty_strings(EnactTest.ProjectInput, :create) == :ok
      assert assert_rejects_empty_strings(EnactTest.ProjectInput, :patch) == :ok
    end

    test "fails for modules that silently coerce" do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          assert_rejects_empty_strings(LooseInput, :create)
        end

      assert error.message =~ "silently coerced"
      assert error.message =~ ":count"
    end

    test "except: skips listed fields" do
      assert assert_rejects_empty_strings(LooseInput, :create, except: [:count]) == :ok
    end

    defmodule EnumInput do
      use Ecto.Schema
      import Enact.InputSchema

      @primary_key false
      embedded_schema do
        field :status, Ecto.Enum, values: [:draft, :live]
      end

      def changeset(base, params, :create), do: cast_input(base, params, [:status])
      def fields(:create), do: [:status]
    end

    test "Ecto.Enum rejections (validation: :inclusion) count as strict" do
      assert assert_rejects_empty_strings(EnumInput, :create) == :ok
    end

    defmodule BinaryInput do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field :payload, :binary
        field :ref, :binary_id
      end

      # stock cast — :binary and :binary_id are skipped: "" is a valid
      # binary, and :binary_id's changeset-level cast accepts any binary
      def changeset(base, params, :create), do: cast(base, params, [:payload, :ref])
      def fields(:create), do: [:payload, :ref]
    end

    test "binary and binary_id fields are skipped" do
      assert assert_rejects_empty_strings(BinaryInput, :create) == :ok
    end

    defmodule CodeType do
      use Ecto.Type

      def type, do: :string
      def cast(""), do: {:error, validation: :format, reason: :empty}
      def cast(value) when is_binary(value), do: {:ok, value}
      def cast(_other), do: :error
      def dump(value), do: {:ok, value}
      def load(value), do: {:ok, value}
    end

    defmodule CustomTagInput do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field :code, CodeType
      end

      # rejects "" with custom error metadata (validation: :format) —
      # any non-:required error counts as strict; empty_values: [] is
      # required for "" to reach the custom type's cast at all
      def changeset(base, params, :create), do: cast(base, params, [:code], empty_values: [])
      def fields(:create), do: [:code]
    end

    test "custom types rejecting with custom error metadata count as strict" do
      assert assert_rejects_empty_strings(CustomTagInput, :create) == :ok
    end

    defmodule RequiredOnlyInput do
      use Ecto.Schema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        field :count, :integer
      end

      # silent coercion caught only by validate_required — still the footgun
      def changeset(base, params, :create) do
        base |> cast(params, [:count]) |> validate_required([:count])
      end

      def fields(:create), do: [:count]
    end

    test "a :required error alone still counts as silent coercion" do
      assert_raise ExUnit.AssertionError, fn ->
        assert_rejects_empty_strings(RequiredOnlyInput, :create)
      end
    end
  end

  describe "build_ctx/1" do
    test "defaults" do
      ctx = build_ctx()

      assert ctx.actor == :test_actor
      assert ctx.params == %{}
      assert ctx.mode == :create
      assert ctx.assigns == %{}
    end

    test "accepts overrides" do
      ctx = build_ctx(actor: :admin, mode: :patch, subject: %{id: 1}, params: %{"a" => 1})

      assert ctx.actor == :admin
      assert ctx.mode == :patch
      assert ctx.subject == %{id: 1}
      assert Enact.provided?(ctx, :a)
    end
  end
end
