defmodule Enact.RateLimitsTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Enact.Error
  alias EnactTest.{FakeRateLimiter, FakeRepo}

  @valid %{"id" => "p1", "name" => "Alpha", "slug" => "alpha"}

  @ten_minutes 600_000
  @hour 3_600_000

  defp run(action, params, opts \\ []) do
    Enact.run(action, params, Keyword.merge([actor: :user, repo: FakeRepo], opts))
  end

  defp dry_run(action, params, opts \\ []) do
    Enact.dry_run(action, params, Keyword.merge([actor: :user, repo: FakeRepo], opts))
  end

  ## Fixtures

  defmodule Limited do
    use Enact.Action

    @impl Enact.Action
    def input, do: EnactTest.ProjectInput

    @impl Enact.Action
    def load_subject(%{"id" => id}, _ctx), do: %{id: id}

    @impl Enact.Action
    def authorize(ctx), do: ctx.actor != :outsider

    @impl Enact.Action
    def rate_limits(ctx) do
      send(self(), {:rate_limits_called, ctx.subject})

      Process.get(:buckets, [
        {"subject:#{ctx.subject.id}", 600_000, 2},
        {"actor:#{ctx.actor}", 3_600_000, 3}
      ])
    end

    @impl Enact.Action
    def execute(changeset, ctx) do
      Process.get(:execute_result, {:ok, Enact.updates(changeset, ctx)})
    end
  end

  defmodule Unlimited do
    use Enact.Action

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}
  end

  defmodule BehaviourOnly do
    @behaviour Enact.Action

    @impl Enact.Action
    def config, do: []

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def load_subject(_params, _ctx), do: :no_subject

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def resolvers, do: []

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}

    @impl Enact.Action
    def after_commit(_result, _ctx), do: :ok
  end

  defmodule RaisingHitLimiter do
    @behaviour Enact.RateLimiter

    @impl Enact.RateLimiter
    def check(_key, _window_ms, _limit), do: :ok

    @impl Enact.RateLimiter
    def hit(_key, _window_ms, _limit), do: raise("store down")
  end

  defmodule AfterCommitSpy do
    use Enact.Action

    @impl Enact.Action
    def input, do: nil

    @impl Enact.Action
    def authorize(_ctx), do: true

    @impl Enact.Action
    def rate_limits(_ctx), do: [{"spy", 60_000, 5}]

    @impl Enact.Action
    def execute(_changeset, _ctx), do: {:ok, :done}

    @impl Enact.Action
    def after_commit(result, _ctx), do: send(self(), {:after_commit, result})
  end

  defmodule BadLimiter do
    @behaviour Enact.RateLimiter

    @impl Enact.RateLimiter
    def check(_key, _window_ms, _limit), do: :nope

    @impl Enact.RateLimiter
    def hit(_key, _window_ms, _limit), do: :ok
  end

  ## Defaults

  test "use Enact.Action defaults rate_limits/1 to []" do
    assert Unlimited.rate_limits(%Enact.Context{}) == []
  end

  test "an action with no buckets never calls the limiter" do
    assert {:ok, :done} = run(Unlimited, %{})
    assert {:ok, _preview} = dry_run(Unlimited, %{})
    refute_received {FakeRateLimiter, _, _}
  end

  test "an action without rate_limits/1 runs with no limits" do
    assert {:ok, :done} = run(BehaviourOnly, %{})
    refute_received {FakeRateLimiter, _, _}
  end

  ## run/3

  describe "run/3" do
    test "checks every bucket, then counts each one after the commit" do
      assert {:ok, _} = run(Limited, @valid)

      assert_received {FakeRateLimiter, :check, "subject:p1"}
      assert_received {FakeRateLimiter, :check, "actor:user"}
      assert_received {FakeRepo, :transaction}
      assert_received {FakeRateLimiter, :hit, "subject:p1"}
      assert_received {FakeRateLimiter, :hit, "actor:user"}

      assert FakeRateLimiter.count("subject:p1", @ten_minutes) == 1
      assert FakeRateLimiter.count("actor:user", @hour) == 1
    end

    test "returns :rate_limited when a bucket is full, before cast and without a write" do
      FakeRateLimiter.put_count("subject:p1", @ten_minutes, 2)

      # invalid params: the rate limit is reported, not the input errors
      assert {:error, %Error{type: :rate_limited, meta: %{retry_after_ms: @ten_minutes}}} =
               run(Limited, %{"id" => "p1"})

      refute_received {FakeRepo, :transaction}
      refute_received {FakeRateLimiter, :hit, _}
    end

    test "retry_after_ms is the longest wait among the full buckets" do
      FakeRateLimiter.put_count("subject:p1", @ten_minutes, 2)
      FakeRateLimiter.put_count("actor:user", @hour, 3)
      Process.put({FakeRateLimiter, :retry_after_ms, "subject:p1"}, 5_000)
      Process.put({FakeRateLimiter, :retry_after_ms, "actor:user"}, 90_000)

      assert {:error, %Error{type: :rate_limited, meta: %{retry_after_ms: 90_000}}} =
               run(Limited, @valid)
    end

    test "one key with two windows keeps two counts" do
      Process.put(:buckets, [{"actor:user", 60_000, 5}, {"actor:user", @hour, 50}])
      assert {:ok, _} = run(Limited, @valid)

      assert FakeRateLimiter.count("actor:user", 60_000) == 1
      assert FakeRateLimiter.count("actor:user", @hour) == 1
    end

    test "allows writes up to the limit" do
      assert {:ok, _} = run(Limited, @valid)
      assert {:ok, _} = run(Limited, @valid)
      assert {:error, %Error{type: :rate_limited}} = run(Limited, @valid)
      assert FakeRateLimiter.count("subject:p1", @ten_minutes) == 2
    end

    test "a forbidden actor never reaches rate_limits/1" do
      assert {:error, %Error{type: :forbidden}} = run(Limited, @valid, actor: :outsider)
      refute_received {:rate_limits_called, _}
      refute_received {FakeRateLimiter, _, _}
    end

    test "rate_limits/1 sees the loaded subject" do
      assert {:ok, _} = run(Limited, @valid)
      assert_received {:rate_limits_called, %{id: "p1"}}
    end

    test "an invalid run counts nothing" do
      assert {:error, %Error{type: :invalid}} = run(Limited, %{"id" => "p1"})
      refute_received {FakeRateLimiter, :hit, _}
    end

    test "a rolled-back run counts nothing" do
      Process.put(:execute_result, {:error, :boom})
      assert {:error, %Error{type: :internal}} = run(Limited, @valid)
      refute_received {FakeRateLimiter, :hit, _}
    end

    test "a digest mismatch counts nothing" do
      assert {:error, %Error{type: :conflict}} =
               run(Limited, @valid, confirm_digest: "sha256:stale")

      refute_received {FakeRateLimiter, :hit, _}
    end
  end

  ## dry_run/3

  describe "dry_run/3" do
    test "checks buckets without counting" do
      assert {:ok, _preview} = dry_run(Limited, @valid)

      assert_received {FakeRateLimiter, :check, "subject:p1"}
      refute_received {FakeRateLimiter, :hit, _}
      assert FakeRateLimiter.count("subject:p1", @ten_minutes) == 0
    end

    test "returns :rate_limited when a bucket is full" do
      FakeRateLimiter.put_count("actor:user", @hour, 3)

      assert {:error, %Error{type: :rate_limited, meta: %{retry_after_ms: @hour}}} =
               dry_run(Limited, @valid)
    end
  end

  ## subject/3 and authorized/3

  test "subject/3 and authorized/3 do not check rate limits" do
    FakeRateLimiter.put_count("subject:p1", @ten_minutes, 2)

    assert {:ok, %{id: "p1"}} =
             Enact.subject(Limited, %{"id" => "p1"}, actor: :user, repo: FakeRepo)

    assert :ok = Enact.authorized(Limited, %{"id" => "p1"}, actor: :user, repo: FakeRepo)
    refute_received {FakeRateLimiter, _, _}
  end

  ## Telemetry

  describe "telemetry" do
    setup do
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach_many(
        handler_id,
        [[:enact, :action, :rate_limited], [:enact, :action, :run, :error]],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "emits [:enact, :action, :rate_limited] once per full bucket" do
      FakeRateLimiter.put_count("subject:p1", @ten_minutes, 2)
      assert {:error, _} = run(Limited, @valid)

      assert_received {:telemetry, [:enact, :action, :rate_limited],
                       %{retry_after_ms: @ten_minutes},
                       %{
                         action: Limited,
                         mode: :create,
                         actor: :user,
                         operation: :run,
                         key: "subject:p1",
                         window_ms: @ten_minutes,
                         limit: 2
                       }}

      refute_received {:telemetry, [:enact, :action, :rate_limited], _, %{key: "actor:user"}}

      assert_received {:telemetry, [:enact, :action, :run, :error], _,
                       %{action: Limited, type: :rate_limited}}
    end

    test "dry runs report operation: :dry_run" do
      FakeRateLimiter.put_count("actor:user", @hour, 3)
      assert {:error, _} = dry_run(Limited, @valid)

      assert_received {:telemetry, [:enact, :action, :rate_limited], _,
                       %{operation: :dry_run, key: "actor:user"}}
    end

    test "a successful run emits no rate_limited event" do
      assert {:ok, _} = run(Limited, @valid)
      refute_received {:telemetry, [:enact, :action, :rate_limited], _, _}
    end
  end

  ## Teaching errors

  test "a malformed bucket raises" do
    Process.put(:buckets, [{"key", 0, 5}])

    assert_raise ArgumentError, ~r/rate_limits\/1 must return a list of/, fn ->
      run(Limited, @valid)
    end
  end
end

defmodule Enact.RateLimitsConfigTest do
  # changes the global :rate_limiter config
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Enact.RateLimitsTest.{AfterCommitSpy, BadLimiter, Limited, RaisingHitLimiter}
  alias EnactTest.{FakeRateLimiter, FakeRepo}

  setup do
    on_exit(fn -> Application.put_env(:enact, :rate_limiter, FakeRateLimiter) end)
  end

  defp run(params), do: Enact.run(Limited, params, actor: :user, repo: FakeRepo)

  test "an action with buckets and no configured limiter raises" do
    Application.delete_env(:enact, :rate_limiter)

    assert_raise ArgumentError, ~r/no rate limiter\s+is configured/, fn ->
      run(%{"id" => "p1", "name" => "Alpha", "slug" => "alpha"})
    end
  end

  test "a raising hit/3 is logged, and the run succeeds and calls after_commit/2" do
    Application.put_env(:enact, :rate_limiter, RaisingHitLimiter)

    log =
      capture_log(fn ->
        assert {:ok, :done} = Enact.run(AfterCommitSpy, %{}, actor: :user, repo: FakeRepo)
      end)

    assert log =~ "hit/3 failed for rate-limit key \"spy\""
    assert log =~ "store down"
    assert_received {:after_commit, :done}
  end

  test "a malformed check/3 return raises" do
    Application.put_env(:enact, :rate_limiter, BadLimiter)

    assert_raise ArgumentError, ~r/check\/3 must return :ok or/, fn ->
      run(%{"id" => "p1", "name" => "Alpha", "slug" => "alpha"})
    end
  end
end
