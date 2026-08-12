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
      end

      # stock cast — but :binary is skipped, since "" is a valid binary
      def changeset(base, params, :create), do: cast(base, params, [:payload])
      def fields(:create), do: [:payload]
    end

    test "binary fields are skipped (\"\" is a valid binary)" do
      assert assert_rejects_empty_strings(BinaryInput, :create) == :ok
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
