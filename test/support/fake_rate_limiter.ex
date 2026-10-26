defmodule EnactTest.FakeRateLimiter do
  @moduledoc """
  Process-local `Enact.RateLimiter`. Counts live in the test process's
  dictionary, keyed by `{key, window_ms}`, so async tests never share
  buckets.

  `check/3` sends `{EnactTest.FakeRateLimiter, :check, key}` and `hit/3`
  sends `{EnactTest.FakeRateLimiter, :hit, key}` to the test process. A
  full bucket's retry time is `Process.get({EnactTest.FakeRateLimiter,
  :retry_after_ms, key}, window_ms)`.
  """

  @behaviour Enact.RateLimiter

  @impl Enact.RateLimiter
  def check(key, window_ms, limit) do
    send(self(), {__MODULE__, :check, key})

    if count(key, window_ms) < limit do
      :ok
    else
      {:error, Process.get({__MODULE__, :retry_after_ms, key}, window_ms)}
    end
  end

  @impl Enact.RateLimiter
  def hit(key, window_ms, _limit) do
    send(self(), {__MODULE__, :hit, key})
    put_count(key, window_ms, count(key, window_ms) + 1)
    :ok
  end

  @doc "Returns the number of hits counted against `{key, window_ms}`."
  def count(key, window_ms), do: Process.get({__MODULE__, :count, key, window_ms}, 0)

  @doc "Sets the number of hits counted against `{key, window_ms}`."
  def put_count(key, window_ms, count),
    do: Process.put({__MODULE__, :count, key, window_ms}, count)
end
