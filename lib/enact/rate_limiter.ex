defmodule Enact.RateLimiter do
  @moduledoc """
  The storage adapter behind `c:Enact.Action.rate_limits/1`.

  Enact does not store rate-limit buckets. Set an adapter module in your
  host app's config:

      config :enact, rate_limiter: MyApp.RateLimiter

  The runner calls the adapter only for actions whose `rate_limits/1`
  returns a non-empty list. If such an action runs with no adapter
  configured, the runner raises `ArgumentError`.

  ## Callbacks

    * `check/3` reports whether a bucket has room for one more write. It
      does not count. `Enact.run/3` and `Enact.dry_run/3` call it after
      `authorize/1`.
    * `hit/3` counts one write against a bucket. `Enact.run/3` calls it
      once per bucket after the transaction commits. The runner ignores
      its return value.

  Each bucket is `{key, window_ms, limit}`: at most `limit` writes per
  `window_ms` milliseconds for `key`. Store counts per `{key, window_ms}`,
  so one key can carry a per-minute and a per-hour limit without the two
  sharing a count. ExRated does this.

  If `hit/3` raises or exits, the runner logs the error and the run
  still succeeds, because the write has already committed.

  ## Example: ExRated

  ExRated uses fixed windows. `inspect_bucket/3` reads a bucket without
  counting, and `check_rate/3` counts.

      defmodule MyApp.RateLimiter do
        @behaviour Enact.RateLimiter

        @impl Enact.RateLimiter
        def check(key, window_ms, limit) do
          {_count, remaining, ms_to_next, _created_at, _updated_at} =
            ExRated.inspect_bucket(key, window_ms, limit)

          if remaining > 0, do: :ok, else: {:error, ms_to_next}
        end

        @impl Enact.RateLimiter
        def hit(key, window_ms, limit) do
          ExRated.check_rate(key, window_ms, limit)
          :ok
        end
      end

  ExRated stores buckets in a local ETS table, so each node counts
  separately. Use a shared store (for example, Redis or your database) if
  limits must hold across nodes.
  """

  @typedoc """
  A bucket identifier. Buckets with equal keys and equal windows share a
  count.
  """
  @type key :: term()

  @doc """
  Returns `:ok` when the bucket has room for one more write, or
  `{:error, retry_after_ms}` with the milliseconds until it does. Does
  not count.
  """
  @callback check(key(), window_ms :: pos_integer(), limit :: pos_integer()) ::
              :ok | {:error, retry_after_ms :: non_neg_integer()}

  @doc """
  Counts one write against the bucket. The runner ignores the return
  value.
  """
  @callback hit(key(), window_ms :: pos_integer(), limit :: pos_integer()) :: term()
end
