defmodule Enact.ErrorTest do
  use ExUnit.Case, async: true

  alias Enact.Error

  test "invalid/1 carries the changeset" do
    changeset = Ecto.Changeset.change({%{}, %{name: :string}})
    assert %Error{type: :invalid, changeset: ^changeset, reason: nil} = Error.invalid(changeset)
  end

  test "invalid/1 rejects non-changesets" do
    assert_raise FunctionClauseError, fn -> apply(Error, :invalid, [%{}]) end
  end

  test "forbidden/0-1" do
    assert %Error{type: :forbidden, reason: nil} = Error.forbidden()
    assert %Error{type: :forbidden, reason: :not_owner} = Error.forbidden(:not_owner)
  end

  test "not_found/0-1" do
    assert %Error{type: :not_found, reason: nil} = Error.not_found()
    assert %Error{type: :not_found, reason: :gone} = Error.not_found(:gone)
  end

  test "conflict/0-2" do
    assert %Error{type: :conflict, reason: nil, meta: %{}} = Error.conflict()
    assert %Error{type: :conflict, reason: :stale} = Error.conflict(:stale)

    assert %Error{type: :conflict, reason: :busy, meta: %{retry_after: 5}} =
             Error.conflict(:busy, %{retry_after: 5})
  end

  test "internal/1 requires a reason" do
    assert %Error{type: :internal, reason: {:boom, "oops"}} = Error.internal({:boom, "oops"})
  end
end
