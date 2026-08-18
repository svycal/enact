defmodule Enact.DryRunTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Enact.{Error, Preview}
  alias EnactTest.{CreateProject, FakeRepo, Project, UpdateProject}

  @valid %{"name" => "Alpha", "slug" => "alpha"}

  defp dry_run(action, params, opts \\ []) do
    Enact.dry_run(action, params, Keyword.merge([actor: :user, repo: FakeRepo], opts))
  end

  defp run(action, params, opts \\ []) do
    Enact.run(action, params, Keyword.merge([actor: :user, repo: FakeRepo], opts))
  end

  ## One-off fixtures

  defmodule RefCreate do
    use Enact.Action

    @impl Enact.Action
    def input, do: EnactTest.ProjectInput

    @impl Enact.Action
    def resolvers, do: [owner: {:owner_id, &__MODULE__.fetch_owner/2}]

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(changeset, ctx), do: {:ok, Enact.updates(changeset, ctx)}

    def fetch_owner("usr_ok", _ctx), do: {:ok, %{id: 42, name: "Jane"}}
    def fetch_owner(_id, _ctx), do: :error
  end

  defmodule WorldGatedCreate do
    use Enact.Action
    import Ecto.Changeset

    @impl Enact.Action
    def input, do: EnactTest.ProjectInput

    @impl Enact.Action
    def validate(changeset, _ctx) do
      if Process.get(:world_ok, true) do
        changeset
      else
        add_error(changeset, :name, "world changed")
      end
    end

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(changeset, ctx), do: {:ok, Enact.updates(changeset, ctx)}
  end

  defmodule Archive do
    use Enact.Action

    @impl Enact.Action
    def config, do: [mode: :patch]

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def load_subject(_params, _ctx), do: Process.get(:enact_subject)

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(_changeset, ctx), do: {:ok, ctx.subject}
  end

  defmodule Unarchive do
    use Enact.Action

    @impl Enact.Action
    def config, do: [mode: :patch]

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def load_subject(_params, _ctx), do: Process.get(:enact_subject)

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(_changeset, ctx), do: {:ok, ctx.subject}
  end

  describe "dry_run/3" do
    test "performs no writes" do
      assert {:ok, %Preview{}} = dry_run(CreateProject, @valid)
      refute_received {FakeRepo, :transaction}
    end

    test "preview updates equal what a subsequent run persists" do
      params = Map.put(@valid, "priority", "5")

      assert {:ok, %Preview{updates: previewed}} = dry_run(CreateProject, params)
      assert {:ok, persisted} = run(CreateProject, params)
      assert previewed == persisted
    end

    test "carries action, mode, and a digest" do
      assert {:ok, preview} = dry_run(CreateProject, @valid)

      assert preview.action == CreateProject
      assert preview.mode == :create
      assert "sha256:" <> _ = preview.digest
    end

    test "patch previews carry only the provided keys" do
      Process.put(:enact_subject, %Project{id: 1, name: "Old", slug: "old", priority: 3})

      assert {:ok, preview} = dry_run(UpdateProject, %{"priority" => 9})
      assert preview.mode == :patch
      assert preview.updates == %{priority: 9}
    end

    test "input: nil actions preview empty updates" do
      Process.put(:enact_subject, %Project{id: 7})

      assert {:ok, %Preview{updates: updates}} = dry_run(Archive, %{})
      assert updates == %{}
    end

    test "resolved lists resolver names, never the loaded structs" do
      params = Map.put(@valid, "owner_id", "usr_ok")

      assert {:ok, preview} = dry_run(RefCreate, params)
      assert preview.resolved == [:owner]
      assert preview.updates.owner_id == "usr_ok"
      refute inspect(preview) =~ "Jane"
    end

    test "shares run/3's error surface: invalid input" do
      assert {:error, %Error{type: :invalid}} = dry_run(CreateProject, %{})
      refute_received {FakeRepo, :transaction}
    end

    test "authorization runs in dry runs" do
      defmodule Denied do
        use Enact.Action

        @impl Enact.Action
        def input, do: nil

        @impl Enact.Action
        def authorize(_ctx), do: false

        @impl Enact.Action
        def execute(_changeset, _ctx), do: {:ok, :done}
      end

      assert {:error, %Error{type: :forbidden}} = dry_run(Denied, %{})
    end

    test "the anonymous gate applies identically" do
      assert {:error, %Error{type: :forbidden, reason: :anonymous_actor}} =
               dry_run(CreateProject, @valid, actor: :anonymous)
    end

    test "resolution failures surface as field errors" do
      params = Map.put(@valid, "owner_id", "usr_missing")

      assert {:error, %Error{type: :invalid, changeset: changeset}} = dry_run(RefCreate, params)
      assert {"not found", _meta} = changeset.errors[:owner_id]
    end
  end

  describe "confirmation digest" do
    test "run/3 with a matching confirm_digest executes" do
      assert {:ok, preview} = dry_run(CreateProject, @valid)
      assert {:ok, _} = run(CreateProject, @valid, confirm_digest: preview.digest)
      assert_received {FakeRepo, :transaction}
    end

    test "a mismatched digest returns :conflict without executing" do
      assert {:error, %Error{type: :conflict, reason: :confirm_digest_mismatch}} =
               run(CreateProject, @valid, confirm_digest: "sha256:beef")

      refute_received {FakeRepo, :transaction}
    end

    test "changed params against a stale digest return :conflict" do
      assert {:ok, preview} = dry_run(CreateProject, @valid)

      assert {:error, %Error{type: :conflict}} =
               run(CreateProject, Map.put(@valid, "name", "Sneaky"),
                 confirm_digest: preview.digest
               )
    end

    test "a matching digest with changed world state still re-validates" do
      Process.put(:world_ok, true)
      assert {:ok, preview} = dry_run(WorldGatedCreate, @valid)

      Process.put(:world_ok, false)

      assert {:error, %Error{type: :invalid}} =
               run(WorldGatedCreate, @valid, confirm_digest: preview.digest)
    end

    test "a digest minted for one action never confirms another" do
      Process.put(:enact_subject, %Project{id: 7})

      # both are input: nil patch actions — identical (empty) updates
      assert {:ok, preview} = dry_run(Archive, %{})

      assert {:error, %Error{type: :conflict, reason: :confirm_digest_mismatch}} =
               run(Unarchive, %{}, confirm_digest: preview.digest)

      refute_received {FakeRepo, :transaction}
    end
  end

  describe "Preview.digest/3" do
    defp digest(updates), do: Preview.digest(SomeAction, :create, updates)

    test "is deterministic for equal maps, including large ones" do
      forward = Map.new(1..40, fn i -> {:"key_#{i}", i} end)
      backward = Map.new(40..1//-1, fn i -> {:"key_#{i}", i} end)

      assert digest(forward) == digest(backward)
    end

    test "binds the action and mode, not just the updates" do
      assert Preview.digest(ActionA, :create, %{}) != Preview.digest(ActionB, :create, %{})
      assert Preview.digest(ActionA, :create, %{}) != Preview.digest(ActionA, :patch, %{})
    end

    test "differs when any value changes" do
      assert digest(%{name: "a"}) != digest(%{name: "b"})
      assert digest(%{name: "a"}) != digest(%{name: "a", extra: nil})
    end

    test "does not collide across value types" do
      assert digest(%{"name" => "a"}) != digest(%{name: "a"})
      assert digest(%{v: "1"}) != digest(%{v: 1})
      assert digest(%{v: 1}) != digest(%{v: 1.0})
      assert digest(%{v: [1, 2]}) != digest(%{v: {1, 2}})
      assert digest(%{v: :atom}) != digest(%{v: "atom"})
    end

    test "encodes structs and dates stably" do
      a = %{due: ~D[2026-01-01], items: [%EnactTest.MilestoneInput{title: "x"}]}
      b = %{due: ~D[2026-01-01], items: [%EnactTest.MilestoneInput{title: "x"}]}

      assert digest(a) == digest(b)
      assert digest(a) != digest(%{a | due: ~D[2026-01-02]})
    end
  end

  describe "telemetry" do
    setup do
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        handler_id,
        [[:enact, :action, :dry_run], [:enact, :action, :dry_run, :error]],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "dry runs emit distinct events" do
      assert {:ok, _} = dry_run(CreateProject, @valid)

      assert_received {:telemetry, [:enact, :action, :dry_run], _measurements,
                       %{action: CreateProject}}
    end

    test "dry-run failures emit the dry_run error event" do
      assert {:error, _} = dry_run(CreateProject, %{})

      assert_received {:telemetry, [:enact, :action, :dry_run, :error], _measurements,
                       %{action: CreateProject, type: :invalid}}
    end
  end
end
