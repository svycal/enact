defmodule EnactTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  doctest Enact

  import Enact.Test, only: [errors_on: 1]

  alias Enact.{Context, Error}
  alias EnactTest.{CreateProject, FakeRepo, Project, ProjectInput, UpdateProject}

  @repo [repo: FakeRepo]
  @valid_create %{"name" => "Alpha", "slug" => "alpha"}

  defp run(action, params, opts \\ []) do
    Enact.run(action, params, Keyword.merge([actor: :user] ++ @repo, opts))
  end

  ## One-off fixture actions

  defmodule PublicAction do
    use Enact.Action

    @impl Enact.Action
    def config, do: [anonymous?: true]

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def execute(_changeset, ctx), do: {:ok, ctx.actor}
  end

  defmodule SpiedLoadAction do
    use Enact.Action

    @impl Enact.Action
    def config, do: [loads_subject?: true]

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def load(_params, _ctx) do
      send(self(), :load_called)
      %Project{id: 1}
    end

    @impl Enact.Action
    def execute(_changeset, ctx), do: {:ok, ctx.subject}
  end

  defmodule ArchiveAction do
    use Enact.Action

    @impl Enact.Action
    def config, do: [mode: :patch, loads_subject?: true]

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def load(_params, _ctx), do: Process.get(:enact_subject)

    @impl Enact.Action
    def validate(_changeset, _ctx), do: raise("validate must not run for input: nil")

    @impl Enact.Action
    def execute(changeset, ctx), do: {:ok, {Enact.updates(changeset, ctx), ctx.subject}}
  end

  defmodule ForbiddenAction do
    use Enact.Action

    @impl Enact.Action
    def input, do: EnactTest.ProjectInput

    @impl Enact.Action
    def authorize(_ctx), do: false

    @impl Enact.Action
    def validate(changeset, _ctx) do
      send(self(), :validate_called)
      changeset
    end

    @impl Enact.Action
    def execute(changeset, ctx), do: {:ok, Enact.updates(changeset, ctx)}
  end

  defmodule ReasonForbiddenAction do
    use Enact.Action

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def authorize(_ctx), do: {:error, :wrong_role}

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  defmodule ValidatedCreate do
    use Enact.Action
    import Ecto.Changeset

    @impl Enact.Action
    def input, do: EnactTest.ProjectInput

    @impl Enact.Action
    def validate(changeset, _ctx) do
      if get_field(changeset, :slug) == "reserved" do
        add_error(changeset, :slug, "is reserved")
      else
        changeset
      end
    end

    @impl Enact.Action
    def execute(changeset, ctx), do: {:ok, Enact.updates(changeset, ctx)}
  end

  defmodule RaisingAfterCommit do
    use Enact.Action

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}

    @impl Enact.Action
    def after_commit(_result, _ctx), do: raise("side effect boom")
  end

  defmodule FailingExecuteAction do
    use Enact.Action

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def execute(_changeset, _ctx), do: Process.get(:enact_execute_result)

    @impl Enact.Action
    def after_commit(_result, _ctx), do: send(self(), :after_commit_called)
  end

  ## Actor enforcement

  describe "actor enforcement" do
    test "missing :actor raises" do
      assert_raise ArgumentError, ~r/:actor option is required/, fn ->
        Enact.run(CreateProject, @valid_create, @repo)
      end
    end

    test "actor: nil raises with a message pointing at anonymous actors" do
      assert_raise ArgumentError, ~r/:anonymous/, fn ->
        Enact.run(CreateProject, @valid_create, [actor: nil] ++ @repo)
      end
    end

    test "anonymous actor against a non-anonymous action is forbidden before any pipeline work" do
      assert {:error, %Error{type: :forbidden, reason: :anonymous_actor}} =
               run(SpiedLoadAction, %{}, actor: :anonymous)

      refute_received :load_called
    end

    test "anonymous actor is permitted by anonymous?: true actions" do
      assert {:ok, :anonymous} = run(PublicAction, %{}, actor: :anonymous)
    end

    test "authenticated actors may still call anonymous-capable actions" do
      assert {:ok, :user} = run(PublicAction, %{})
    end
  end

  ## Option validation

  describe "option validation" do
    test "unknown run options raise" do
      assert_raise ArgumentError, ~r/asigns/, fn ->
        Enact.run(CreateProject, @valid_create, [actor: :user, asigns: %{}] ++ @repo)
      end
    end

    test "a misspelled confirm_digest cannot silently skip confirmation" do
      assert_raise ArgumentError, ~r/confirm_diget/, fn ->
        Enact.run(
          CreateProject,
          @valid_create,
          [actor: :user, confirm_diget: "sha256:x"] ++ @repo
        )
      end
    end

    test "dry_run rejects confirm_digest" do
      assert_raise ArgumentError, ~r/confirm_digest/, fn ->
        Enact.dry_run(
          CreateProject,
          @valid_create,
          [actor: :user, confirm_digest: "sha256:x"] ++ @repo
        )
      end
    end
  end

  ## Repo resolution

  describe "repo resolution" do
    test "repo comes from the :repo option" do
      assert {:ok, _} = run(CreateProject, @valid_create)
      assert_received {FakeRepo, :transaction}
    end

    test "repo falls back to app config" do
      Application.put_env(:enact, :repo, FakeRepo)
      on_exit(fn -> Application.delete_env(:enact, :repo) end)

      assert {:ok, _} = Enact.run(CreateProject, @valid_create, actor: :user)
      assert_received {FakeRepo, :transaction}
    end

    test "no repo anywhere raises" do
      assert_raise ArgumentError, ~r/no repo configured/, fn ->
        Enact.run(CreateProject, @valid_create, actor: :user)
      end
    end
  end

  ## Config

  describe "config" do
    test "an invalid mode raises a teaching error" do
      defmodule BadModeAction do
        use Enact.Action

        @impl Enact.Action
        def config, do: [mode: :upsert]

        @impl Enact.Action
        def input, do: nil

        @impl Enact.Action
        def execute(_changeset, _ctx), do: {:ok, :done}
      end

      assert_raise ArgumentError, ~r/expected :create or :patch/, fn ->
        run(BadModeAction, %{})
      end
    end
  end

  ## Load

  describe "load" do
    test "actions without loads_subject? skip load entirely" do
      assert {:ok, _} = run(CreateProject, @valid_create)
    end

    test "the loaded subject lands in ctx.subject" do
      assert {:ok, %Project{id: 1}} = run(SpiedLoadAction, %{})
      assert_received :load_called
    end

    test "load returning nil produces :not_found" do
      Process.delete(:enact_subject)
      assert {:error, %Error{type: :not_found}} = run(UpdateProject, %{"name" => "New"})
    end

    test "load returning {:error, reason} produces :not_found with the reason" do
      defmodule ErrorLoadAction do
        use Enact.Action

        @impl Enact.Action
        def config, do: [loads_subject?: true]

        @impl Enact.Action
        def input, do: nil

        @impl Enact.Action
        def load(_params, _ctx), do: {:error, :ambiguous_slug}

        @impl Enact.Action
        def execute(_changeset, _ctx), do: {:ok, :done}
      end

      assert {:error, %Error{type: :not_found, reason: :ambiguous_slug}} =
               run(ErrorLoadAction, %{})
    end
  end

  ## Authorize

  describe "authorize" do
    test "false produces :forbidden and runs before validate" do
      result = run(ForbiddenAction, %{"priority" => -5})

      assert {:error, %Error{type: :forbidden, changeset: nil}} = result
      refute_received :validate_called
    end

    test "{:error, reason} produces :forbidden carrying the reason" do
      assert {:error, %Error{type: :forbidden, reason: :wrong_role}} =
               run(ReasonForbiddenAction, %{})
    end
  end

  ## Cast + validate

  describe "cast and validate" do
    test "cast errors and module validations surface together in one :invalid" do
      # missing required name + out-of-bounds priority + reserved slug:
      # all three collected, no fast-fail
      result = run(ValidatedCreate, %{"slug" => "reserved", "priority" => -1})

      assert {:error, %Error{type: :invalid, changeset: changeset}} = result
      assert %{name: _, priority: _, slug: _} = errors_on(changeset)
    end

    test "valid create passes the changeset through validate to execute" do
      assert {:ok, %{name: "Alpha", slug: "alpha"}} = run(ValidatedCreate, @valid_create)
    end

    test "input: nil skips cast and validate" do
      Process.put(:enact_subject, %Project{id: 7})

      assert {:ok, {%{}, %Project{id: 7}}} = run(ArchiveAction, %{})
    end
  end

  ## Execute + after_commit

  describe "execute and after_commit" do
    test "execute runs inside a transaction; after_commit runs on success" do
      Process.put(:enact_execute_result, {:ok, :done})

      assert {:ok, :done} = run(FailingExecuteAction, %{})
      assert_received {FakeRepo, :transaction}
      assert_received :after_commit_called
    end

    test "a changeset error from execute is promoted to :invalid" do
      failed =
        Ecto.Changeset.change({%{}, %{slug: :string}})
        |> Ecto.Changeset.add_error(:slug, "has already been taken")

      Process.put(:enact_execute_result, {:error, failed})

      assert {:error, %Error{type: :invalid, changeset: ^failed}} =
               run(FailingExecuteAction, %{})

      refute_received :after_commit_called
    end

    test "an Enact.Error from execute passes through" do
      Process.put(:enact_execute_result, {:error, Error.conflict(:claimed)})

      assert {:error, %Error{type: :conflict, reason: :claimed}} =
               run(FailingExecuteAction, %{})
    end

    test "any other execute failure is :internal" do
      Process.put(:enact_execute_result, {:error, :boom})

      assert {:error, %Error{type: :internal, reason: :boom}} = run(FailingExecuteAction, %{})
      refute_received :after_commit_called
    end

    test "a non-tuple execute return is :internal" do
      Process.put(:enact_execute_result, :done)

      assert {:error, %Error{type: :internal, reason: {:bad_execute_return, :done}}} =
               run(FailingExecuteAction, %{})
    end
  end

  ## PATCH pipeline

  describe "patch mode" do
    setup do
      Process.put(:enact_subject, %Project{id: 1, name: "Old", slug: "old", priority: 3})
      :ok
    end

    test "omitted keys are untouched; provided keys carry casted values" do
      assert {:ok, updates} = run(UpdateProject, %{"name" => "New"})
      assert updates == %{name: "New"}
    end

    test "explicit null clears an optional scalar" do
      assert {:ok, updates} = run(UpdateProject, %{"priority" => nil})
      assert updates == %{priority: nil}
    end

    test "explicit null on a required field is :invalid" do
      assert {:error, %Error{type: :invalid, changeset: changeset}} =
               run(UpdateProject, %{"name" => nil})

      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "an omitted required-but-populated field passes validate_required via the base" do
      assert {:ok, %{priority: 9}} = run(UpdateProject, %{"priority" => 9})
    end

    test "a provided-identical value persists as a harmless no-op write" do
      assert {:ok, %{name: "Old"}} = run(UpdateProject, %{"name" => "Old"})
    end

    test "provided-but-uncastable keys are ignored (slug immutable on patch)" do
      assert {:ok, updates} = run(UpdateProject, %{"slug" => "new-slug", "name" => "New"})
      assert updates == %{name: "New"}
    end

    test "[] clears an embed array" do
      assert {:ok, updates} = run(UpdateProject, %{"milestones" => []})
      assert updates == %{milestones: []}
    end

    test "provided embeds are dumped to plain maps with scalar structs intact" do
      assert {:ok, %{milestones: [item]}} =
               run(UpdateProject, %{
                 "milestones" => [%{"title" => "Ship", "due_on" => "2026-09-01"}]
               })

      assert item == %{title: "Ship", due_on: ~D[2026-09-01], owner_id: nil}
    end

    test "item-level errors nest under the embed key" do
      assert {:error, %Error{type: :invalid, changeset: changeset}} =
               run(UpdateProject, %{"milestones" => [%{"due_on" => "2026-01-01"}]})

      assert %{milestones: [%{title: ["can't be blank"]}]} = errors_on(changeset)
    end
  end

  ## Create extraction

  describe "create mode extraction" do
    test "omitted optionals are absent from updates (fall to DB defaults)" do
      assert {:ok, updates} = run(CreateProject, @valid_create)
      assert updates == %{name: "Alpha", slug: "alpha"}
      refute Map.has_key?(updates, :priority)
    end

    test "values are casted, not raw" do
      assert {:ok, %{priority: 5}} =
               run(CreateProject, Map.put(@valid_create, "priority", "5"))
    end
  end

  ## provided?/2

  describe "provided?/2" do
    defp ctx_with(params), do: %Context{actor: :user, params: params}

    test "top-level presence, string- or atom-keyed" do
      assert Enact.provided?(ctx_with(%{"name" => "x"}), :name)
      assert Enact.provided?(ctx_with(%{name: "x"}), :name)
      refute Enact.provided?(ctx_with(%{"name" => "x"}), :slug)
    end

    test "a key provided with a nil value counts as provided" do
      assert Enact.provided?(ctx_with(%{"name" => nil}), :name)
    end

    test "path form descends maps and indexes lists" do
      params = %{"items" => [%{"qty" => 1}, %{"sku" => "a", "qty" => nil}]}

      assert Enact.provided?(ctx_with(params), [:items, 0, :qty])
      assert Enact.provided?(ctx_with(params), [:items, 1, :qty])
      refute Enact.provided?(ctx_with(params), [:items, 0, :sku])
    end

    test "unreachable paths return false without raising" do
      params = %{"items" => [%{"qty" => 1}], "note" => "hi"}
      ctx = ctx_with(params)

      refute Enact.provided?(ctx, [:missing, 0, :qty])
      refute Enact.provided?(ctx, [:items, 5, :qty])
      refute Enact.provided?(ctx, [:items, -1, :qty])
      refute Enact.provided?(ctx, [:note, 0])
      refute Enact.provided?(ctx, [:note, :deep])
      refute Enact.provided?(ctx, [:items, 0, :qty, :deeper])
    end

    test "never converts client strings to atoms" do
      # key not existing as an atom anywhere must simply be absent
      refute Enact.provided?(ctx_with(%{"totally_unknown_client_key" => 1}), :other)
    end
  end

  ## updates/2 (direct unit coverage beyond the pipeline tests)

  describe "updates/2" do
    test "returns %{} for input-less changesets" do
      changeset = Ecto.Changeset.change({%{}, %{}})
      ctx = %Context{actor: :user, params: %{"anything" => 1}, mode: :create}

      assert Enact.updates(changeset, ctx) == %{}
    end

    test "a wrong base cannot corrupt provided values" do
      # base says name is "Wrong"; caller provides "Right" — updates carries
      # the provided value regardless of base correctness
      ctx = %Context{actor: :user, params: %{"name" => "Right"}, mode: :patch}
      base = %ProjectInput{name: "Wrong", slug: "s"}
      changeset = ProjectInput.changeset(base, ctx.params, :patch)

      assert Enact.updates(changeset, ctx) == %{name: "Right"}
    end
  end

  ## Telemetry

  describe "telemetry" do
    setup do
      ref = make_ref()
      handler_id = {__MODULE__, ref}

      :telemetry.attach_many(
        handler_id,
        [[:enact, :action, :run], [:enact, :action, :run, :error]],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "success emits [:enact, :action, :run]" do
      assert {:ok, _} = run(CreateProject, @valid_create)

      assert_received {:telemetry, [:enact, :action, :run], %{duration: duration},
                       %{action: CreateProject, mode: :create, actor: :user}}

      assert is_integer(duration)
    end

    test "failure emits [:enact, :action, :run, :error] with the error type" do
      assert {:error, _} = run(ForbiddenAction, @valid_create)

      assert_received {:telemetry, [:enact, :action, :run, :error], _measurements,
                       %{action: ForbiddenAction, type: :forbidden}}
    end

    test "a raising after_commit propagates, but the write committed and the run event fired" do
      assert_raise RuntimeError, "side effect boom", fn ->
        run(RaisingAfterCommit, %{})
      end

      assert_received {FakeRepo, :transaction}

      assert_received {:telemetry, [:enact, :action, :run], _measurements,
                       %{action: RaisingAfterCommit}}
    end
  end

  ## merged/4

  defmodule Flags do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :a, :boolean
      field :b, :boolean
    end

    def changeset(item, params), do: cast(item, params, [:a, :b])
  end

  defmodule ConfigInput do
    use Ecto.Schema
    use Enact.InputSchema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :name, :string
      embeds_one :flags, Flags
    end

    @impl Enact.InputSchema
    def changeset(base, params, _mode) do
      base |> cast_input(params, [:name]) |> cast_embed(:flags)
    end

    @impl Enact.InputSchema
    def fields(_mode), do: [:name, :flags]
  end

  defmodule FlagsSubject do
    defstruct flags: %{a: true, b: true}
  end

  defp merged_for(params, subject) do
    ctx = Enact.Test.build_ctx(params: params, subject: subject, mode: :patch)
    changeset = ConfigInput.changeset(%ConfigInput{}, params, :patch)
    Enact.merged(changeset, ctx, :flags)
  end

  describe "merged/4" do
    test "provided sub-keys read incoming; omitted sub-keys read current" do
      assert merged_for(%{"flags" => %{"b" => false}}, %FlagsSubject{}) ==
               %{a: true, b: false}
    end

    test "an explicitly-null sub-key reads nil, not the current value" do
      assert merged_for(%{"flags" => %{"a" => nil}}, %FlagsSubject{}) == %{a: nil, b: true}
    end

    test "a wholly-omitted embed reads current values" do
      assert merged_for(%{"name" => "x"}, %FlagsSubject{}) == %{a: true, b: true}
    end

    test "a whole-object null reads all nil (the object is being cleared)" do
      assert merged_for(%{"flags" => nil}, %FlagsSubject{}) == %{a: nil, b: nil}
    end

    test "with no current object, unprovided keys read nil" do
      assert merged_for(%{"flags" => %{"a" => false}}, %FlagsSubject{flags: nil}) ==
               %{a: false, b: nil}

      assert merged_for(%{"flags" => %{"a" => false}}, nil) == %{a: false, b: nil}
    end

    test "an explicit key list restricts the view" do
      ctx =
        Enact.Test.build_ctx(
          params: %{"flags" => %{"b" => false}},
          subject: %FlagsSubject{},
          mode: :patch
        )

      changeset = ConfigInput.changeset(%ConfigInput{}, ctx.params, :patch)

      assert Enact.merged(changeset, ctx, :flags, [:b]) == %{b: false}
    end

    test "a non-embed field raises a teaching error" do
      ctx = Enact.Test.build_ctx(params: %{}, mode: :patch)
      changeset = ConfigInput.changeset(%ConfigInput{}, %{}, :patch)

      assert_raise ArgumentError, ~r/to be an embed/, fn ->
        Enact.merged(changeset, ctx, :name)
      end
    end
  end
end
