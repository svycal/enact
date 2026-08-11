defmodule EnactTest.FakeRepo do
  @moduledoc """
  In-memory stand-in for an Ecto repo. The runner only ever calls
  `transaction/1` and `rollback/1` on the repo (`execute/2` is host code),
  so a database-free fake is enough for package tests.

  Every transaction sends `{EnactTest.FakeRepo, :transaction}` to the test
  process, so "dry runs perform no writes" is assertable with `refute_received`.
  """

  def transaction(fun, _opts \\ []) when is_function(fun, 0) do
    send(self(), {__MODULE__, :transaction})

    try do
      {:ok, fun.()}
    catch
      :throw, {__MODULE__, :rollback, value} -> {:error, value}
    end
  end

  def rollback(value), do: throw({__MODULE__, :rollback, value})

  @doc """
  Records the query and returns `Process.get(:fake_repo_exists?, false)`,
  so tests control the answer per-process.
  """
  def exists?(query, _opts \\ []) do
    send(self(), {__MODULE__, :exists?, query})
    Process.get(:fake_repo_exists?, false)
  end
end
