defmodule Enact.SubjectTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Enact.Error
  alias EnactTest.{CreateProject, FakeRepo, Project, UpdateProject}

  defp subject(action, params, opts \\ []) do
    Enact.subject(action, params, Keyword.merge([actor: :user, repo: FakeRepo], opts))
  end

  defp authorized(action, params, opts \\ []) do
    Enact.authorized(action, params, Keyword.merge([actor: :user, repo: FakeRepo], opts))
  end

  defmodule SpyInput do
    use Ecto.Schema
    use Enact.InputSchema

    @primary_key false
    embedded_schema do
      field :name, :string
    end

    @impl Enact.InputSchema
    def changeset(base, params, _mode) do
      send(self(), :cast_called)
      Enact.InputSchema.cast_input(base, params, [:name])
    end

    @impl Enact.InputSchema
    def fields(_mode), do: [:name]
  end

  defmodule SpyCreate do
    use Enact.Action

    @impl Enact.Action
    def input, do: SpyInput

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  defmodule SpyPatchInput do
    use Ecto.Schema
    use Enact.InputSchema

    @primary_key false
    embedded_schema do
      field :name, :string
    end

    @impl Enact.InputSchema
    def changeset(base, params, _mode) do
      send(self(), :cast_called)
      Enact.InputSchema.cast_input(base, params, [:name])
    end

    @impl Enact.InputSchema
    def fields(_mode), do: [:name]

    @impl Enact.InputSchema
    def from_subject(_subject), do: %__MODULE__{name: "Old"}
  end

  defmodule SpyPatch do
    use Enact.Action

    @impl Enact.Action
    def config, do: [mode: :patch]

    @impl Enact.Action
    def input, do: SpyPatchInput

    @impl Enact.Action
    def load_subject(_params, _ctx), do: Process.get(:enact_subject)

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  defmodule Denied do
    use Enact.Action

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def authorize(_ctx), do: false

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  defmodule ReasonDenied do
    use Enact.Action

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def authorize(_ctx), do: {:error, :wrong_role}

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  defmodule Missing do
    use Enact.Action

    @impl Enact.Action
    def config, do: [mode: :patch]

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def load_subject(_params, _ctx), do: nil

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  describe "subject/3" do
    test "returns the loaded subject" do
      project = %Project{id: 1, name: "Old", slug: "old"}
      Process.put(:enact_subject, project)

      assert {:ok, ^project} = subject(UpdateProject, %{"id" => "1"})
    end

    test "raises when the action has no subject" do
      assert_raise ArgumentError, ~r/Enact.authorized\/3/, fn ->
        subject(CreateProject, %{})
      end
    end

    test "does not cast, validate, or write" do
      project = %Project{id: 1, name: "Old", slug: "old"}
      Process.put(:enact_subject, project)

      assert {:ok, ^project} = subject(SpyPatch, %{"id" => "1", "name" => "x"})
      refute_received :cast_called
      refute_received {FakeRepo, :transaction}
    end

    test "load_subject returning nil is :not_found" do
      assert {:error, %Error{type: :not_found}} = subject(Missing, %{"id" => "missing"})
    end

    test "authorize false is :forbidden" do
      assert {:error, %Error{type: :forbidden}} = subject(Denied, %{})
    end

    test "{:error, reason} is :forbidden carrying the reason" do
      assert {:error, %Error{type: :forbidden, reason: :wrong_role}} =
               subject(ReasonDenied, %{})
    end

    test "the anonymous gate applies" do
      assert {:error, %Error{type: :forbidden, reason: :anonymous_actor}} =
               subject(UpdateProject, %{"id" => "1"}, actor: :anonymous)
    end

    test "actor: nil raises" do
      assert_raise ArgumentError, ~r/:anonymous/, fn ->
        Enact.subject(UpdateProject, %{"id" => "1"}, actor: nil, repo: FakeRepo)
      end
    end
  end

  describe "authorized/3" do
    test "returns :ok when the actor may perform the action" do
      assert :ok = authorized(CreateProject, %{})
    end

    test "still loads so authorize/1 sees the subject" do
      project = %Project{id: 1, name: "Old", slug: "old"}
      Process.put(:enact_subject, project)

      defmodule SeesSubject do
        use Enact.Action

        @impl Enact.Action
        def config, do: [mode: :patch]

        @impl Enact.Action
        def input, do: nil

        @impl Enact.Action
        def load_subject(_params, _ctx), do: Process.get(:enact_subject)

        @impl Enact.Action
        def authorize(ctx) do
          send(self(), {:authorized_subject, ctx.subject})
          true
        end

        @impl Enact.Action
        def execute(_changeset, _ctx), do: {:ok, :done}
      end

      assert :ok = authorized(SeesSubject, %{"id" => "1"})
      assert_received {:authorized_subject, ^project}
    end

    test "does not cast, validate, or write" do
      assert :ok = authorized(SpyCreate, %{"name" => "x"})
      refute_received :cast_called
      refute_received {FakeRepo, :transaction}
    end

    test "load_subject returning nil is :not_found" do
      assert {:error, %Error{type: :not_found}} = authorized(Missing, %{"id" => "missing"})
    end

    test "authorize false is :forbidden" do
      assert {:error, %Error{type: :forbidden}} = authorized(Denied, %{})
    end

    test "{:error, reason} is :forbidden carrying the reason" do
      assert {:error, %Error{type: :forbidden, reason: :wrong_role}} =
               authorized(ReasonDenied, %{})
    end

    test "the anonymous gate applies" do
      assert {:error, %Error{type: :forbidden, reason: :anonymous_actor}} =
               authorized(CreateProject, %{}, actor: :anonymous)
    end
  end

  describe "telemetry" do
    setup do
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        handler_id,
        [
          [:enact, :action, :subject],
          [:enact, :action, :subject, :error],
          [:enact, :action, :authorized],
          [:enact, :action, :authorized, :error]
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "subject success emits a distinct event" do
      Process.put(:enact_subject, %Project{id: 1, name: "Old", slug: "old"})
      assert {:ok, _} = subject(UpdateProject, %{"id" => "1"})

      assert_received {:telemetry, [:enact, :action, :subject], _measurements,
                       %{action: UpdateProject}}
    end

    test "authorized success emits a distinct event" do
      assert :ok = authorized(CreateProject, %{})

      assert_received {:telemetry, [:enact, :action, :authorized], _measurements,
                       %{action: CreateProject}}
    end

    test "failures emit the matching error event" do
      assert {:error, _} = authorized(Denied, %{})

      assert_received {:telemetry, [:enact, :action, :authorized, :error], _measurements,
                       %{action: Denied, type: :forbidden}}
    end
  end
end
