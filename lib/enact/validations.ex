defmodule Enact.Validations do
  @moduledoc """
  Changeset-pipeline combinators for action `validate/2` callbacks.

  These compose *into* ordinary `Ecto.Changeset` pipelines — they are
  never replacements for `validate_*` functions. The dividing line for
  where a rule lives: payload-intrinsic rules (format, bounds, inclusion)
  belong in the input module's own validations; operation- and actor-aware
  rules belong in the action's `validate/2`.
  """

  import Ecto.Query

  @doc """
  Cheap gates expensive: no-ops when the changeset is already invalid,
  otherwise applies `fun`. All DB-backed checks go through it, so garbage
  input never triggers queries:

      def validate(changeset, ctx) do
        changeset
        |> validate_length(:note, max: 500)
        |> check(&unique(&1, :slug, query: Project, repo: ctx.repo, scope: [org_id: ctx.actor.org_id], except: ctx.subject))
      end
  """
  @spec check(Ecto.Changeset.t(), (Ecto.Changeset.t() -> Ecto.Changeset.t())) ::
          Ecto.Changeset.t()
  def check(%Ecto.Changeset{valid?: false} = changeset, _fun), do: changeset
  def check(%Ecto.Changeset{} = changeset, fun) when is_function(fun, 1), do: fun.(changeset)

  @doc """
  Scoped uniqueness for input changesets. Skips when the field has no
  change (an untouched value on PATCH is already persisted).

  Options:

    * `:query` (required) — the persistence queryable to check against
    * `:repo` (required) — usually `ctx.repo`
    * `:scope` — keyword of extra column/value pairs to filter by
      (tenancy scoping)
    * `:except` — exclude the current row on PATCH. A struct (uses its
      primary key), an id (`integer` / `binary`, compared to `id`), or a
      keyword of column/value pairs. Soft-deletes stay on `:query`
      (e.g. `from(s in Schema, where: is_nil(s.deleted_at))`).

  Adds `"has already been taken"` on the field, tagged
  `validation: :unique`. Like Ecto's `unsafe_validate_unique/4` this is
  best-effort pre-flight UX — keep the DB unique index and declared
  constraint as the source of truth; the runner promotes constraint-error
  changesets from execute to `:invalid`.
  """
  @spec unique(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def unique(%Ecto.Changeset{} = changeset, field, opts) when is_atom(field) do
    case Ecto.Changeset.get_change(changeset, field) do
      nil ->
        changeset

      value ->
        repo = Keyword.fetch!(opts, :repo)
        scope = Keyword.get(opts, :scope, [])

        query =
          opts
          |> Keyword.fetch!(:query)
          |> where(^([{field, value}] ++ scope))
          |> apply_except(Keyword.get(opts, :except))

        if repo.exists?(query) do
          Ecto.Changeset.add_error(changeset, field, "has already been taken",
            validation: :unique
          )
        else
          changeset
        end
    end
  end

  defp apply_except(query, nil), do: query

  defp apply_except(query, %_{} = struct) do
    case Ecto.primary_key(struct) do
      [] ->
        raise ArgumentError, "Enact.Validations.unique/3 except: struct has no primary key"

      keys ->
        Enum.reduce(keys, query, fn {pk, pk_value}, acc ->
          exclude_column(acc, pk, pk_value)
        end)
    end
  end

  defp apply_except(query, id) when is_integer(id) or is_binary(id) do
    exclude_column(query, :id, id)
  end

  defp apply_except(query, [{_, _} | _] = pairs) do
    Enum.reduce(pairs, query, fn {pk, pk_value}, acc ->
      exclude_column(acc, pk, pk_value)
    end)
  end

  defp apply_except(_query, other) do
    raise ArgumentError,
          "Enact.Validations.unique/3 except: expected a struct, id, or keyword, got: " <>
            inspect(other)
  end

  defp exclude_column(_query, pk, nil) do
    raise ArgumentError, "Enact.Validations.unique/3 except: #{inspect(pk)} is nil"
  end

  defp exclude_column(query, pk, pk_value) do
    where(query, [row], field(row, ^pk) != ^pk_value)
  end
end
