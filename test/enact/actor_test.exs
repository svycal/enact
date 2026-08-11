defmodule Enact.ActorTest do
  use ExUnit.Case, async: true

  defmodule GuestScope do
    defstruct [:user, :session_id]
  end

  defimpl Enact.Actor, for: GuestScope do
    def anonymous?(%{user: nil}), do: true
    def anonymous?(_scope), do: false
  end

  defmodule PlainStruct do
    defstruct [:id]
  end

  test "the bare :anonymous atom is anonymous" do
    assert Enact.Actor.anonymous?(:anonymous)
  end

  test "other atoms are not anonymous" do
    refute Enact.Actor.anonymous?(:admin)
    refute Enact.Actor.anonymous?(true)
  end

  test "arbitrary terms fall back to not anonymous" do
    refute Enact.Actor.anonymous?(%{id: 1})
    refute Enact.Actor.anonymous?(%PlainStruct{id: 1})
    refute Enact.Actor.anonymous?("user-1")
    refute Enact.Actor.anonymous?(42)
  end

  test "host apps can implement the protocol for scope structs" do
    assert Enact.Actor.anonymous?(%GuestScope{user: nil, session_id: "abc"})
    refute Enact.Actor.anonymous?(%GuestScope{user: %{id: 1}})
  end
end
