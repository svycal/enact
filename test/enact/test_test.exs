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
