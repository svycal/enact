defmodule Enact.DelegatesTest do
  use ExUnit.Case, async: true

  alias EnactTest.{CreateProject, FakeRepo}

  @opts [actor: :user, repo: FakeRepo]
  @valid %{"name" => "Alpha", "slug" => "alpha"}

  defmodule CreateXMLThing do
    use Enact.Action

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :xml}
  end

  defmodule Admin.CreateUser do
  end

  defmodule Staff.CreateUser do
  end

  defmodule XMLContext do
    use Enact.Delegates, actions: [Enact.DelegatesTest.CreateXMLThing]
  end

  defmodule AliasedContext do
    alias EnactTest.CreateProject
    use Enact.Delegates, actions: [CreateProject]
  end

  defmodule EmptyContext do
    use Enact.Delegates, actions: []
  end

  test "last-segment names are underscored" do
    assert {:ok, :xml} = XMLContext.create_xml_thing(%{}, @opts)

    assert {:ok, %Enact.Preview{action: CreateXMLThing, updates: %{}}} =
             XMLContext.create_xml_thing_dry_run(%{}, @opts)

    assert :ok = XMLContext.create_xml_thing_authorized(%{}, @opts)
  end

  test "aliases expand at the use site" do
    assert function_exported?(AliasedContext, :create_project, 2)
    assert function_exported?(AliasedContext, :create_project_dry_run, 2)
    assert function_exported?(AliasedContext, :create_project_subject, 2)
    assert function_exported?(AliasedContext, :create_project_authorized, 2)
  end

  test "run, dry_run, subject, and authorized wrappers match calling the runner directly" do
    assert AliasedContext.create_project(@valid, @opts) ==
             Enact.run(CreateProject, @valid, @opts)

    assert AliasedContext.create_project_dry_run(@valid, @opts) ==
             Enact.dry_run(CreateProject, @valid, @opts)

    assert AliasedContext.create_project_authorized(%{}, @opts) ==
             Enact.authorized(CreateProject, %{}, @opts)

    assert_raise ArgumentError, ~r/Enact.authorized\/3/, fn ->
      AliasedContext.create_project_subject(%{}, @opts)
    end

    invalid = %{"name" => "", "slug" => "alpha"}

    assert {:error, %Enact.Error{type: :invalid}} =
             AliasedContext.create_project(invalid, @opts)

    assert {:error, %Enact.Error{type: :invalid}} =
             AliasedContext.create_project_dry_run(invalid, @opts)
  end

  test "empty actions list generates no functions" do
    refute function_exported?(EmptyContext, :create_project, 2)
  end

  test "duplicate last-segment names raise" do
    assert_raise ArgumentError, ~r/create_user\/2/, fn ->
      defmodule DuplicateNames do
        use Enact.Delegates,
          actions: [
            Enact.DelegatesTest.Admin.CreateUser,
            Enact.DelegatesTest.Staff.CreateUser
          ]
      end
    end
  end

  test "rejects a bare list of modules" do
    assert_raise ArgumentError, ~r/expects options with an :actions key/, fn ->
      defmodule BareList do
        use Enact.Delegates, [EnactTest.CreateProject]
      end
    end
  end

  test "rejects a missing :actions key" do
    assert_raise ArgumentError, ~r/expects options with an :actions key/, fn ->
      defmodule MissingActions do
        use Enact.Delegates
      end
    end
  end

  test "rejects an unknown option" do
    assert_raise ArgumentError, ~r/does not recognize option :dry_run/, fn ->
      defmodule UnknownOption do
        use Enact.Delegates, actions: [EnactTest.CreateProject], dry_run: false
      end
    end
  end

  test "rejects a non-list :actions value" do
    assert_raise ArgumentError, ~r/:actions must be a list of action modules/, fn ->
      defmodule NonListActions do
        use Enact.Delegates, actions: EnactTest.CreateProject
      end
    end
  end

  test "rejects a non-module entry" do
    assert_raise ArgumentError, ~r/:actions must be a list of action modules/, fn ->
      defmodule NonModule do
        use Enact.Delegates, actions: ["CreateContact"]
      end
    end
  end
end
