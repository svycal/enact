defmodule EnactTest.FakeRateLimiter do
  @moduledoc """
  Process-local `Enact.RateLimiter`. Counts live in the test process's
  dictionary, keyed by `{key, window_ms}`, so async tests never share
  buckets.

  `check/3` sends `{EnactTest.FakeRateLimiter, :check, key}` and `hit/3`
  sends `{EnactTest.FakeRateLimiter, :hit, key}` to the test process. A
  full bucket's retry time is `Process.get({EnactTest.FakeRateLimiter,
  :retry_after_ms, key}, window_ms)`.

  `fill_after_check(key)` fills the bucket after its next `check/3`
  returns, the way a concurrent run that counts first would.
  """

  @behaviour Enact.RateLimiter

  @impl Enact.RateLimiter
  def check(key, window_ms, limit) do
    send(self(), {__MODULE__, :check, key})

    result =
      if count(key, window_ms) < limit do
        :ok
      else
        {:error, retry_after_ms(key, window_ms)}
      end

    if Process.delete({__MODULE__, :fill_after_check, key}) do
      put_count(key, window_ms, limit)
    end

    result
  end

  @impl Enact.RateLimiter
  def hit(key, window_ms, limit) do
    send(self(), {__MODULE__, :hit, key})
    count = count(key, window_ms)

    if count < limit do
      put_count(key, window_ms, count + 1)
      :ok
    else
      {:error, retry_after_ms(key, window_ms)}
    end
  end

  @doc "Fills the bucket for `key` after its next `check/3` returns."
  def fill_after_check(key), do: Process.put({__MODULE__, :fill_after_check, key}, true)

  @doc "Returns the number of hits counted against `{key, window_ms}`."
  def count(key, window_ms), do: Process.get({__MODULE__, :count, key, window_ms}, 0)

  defp retry_after_ms(key, window_ms),
    do: Process.get({__MODULE__, :retry_after_ms, key}, window_ms)

  @doc "Sets the number of hits counted against `{key, window_ms}`."
  def put_count(key, window_ms, count),
    do: Process.put({__MODULE__, :count, key, window_ms}, count)
end
