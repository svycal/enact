defmodule Enact.Validations do
  @moduledoc """
  Changeset-pipeline combinators for action `validate/2` callbacks.

  These compose *into* ordinary `Ecto.Changeset` pipelines — they are
  never replacements for `validate_*` functions. The dividing line for
  where a rule lives: payload-intrinsic rules (format, bounds, inclusion)
  belong in the input module's own validations; operation- and actor-aware
  rules belong in the action's `validate/2`.
  """

  import Ecto.Query, only: [where: 2]

  @doc """
  Cheap gates expensive: no-ops when the changeset is already invalid,
  otherwise applies `fun`. All DB-backed checks go through it, so garbage
  input never triggers queries:

      def validate(changeset, ctx) do
        changeset
        |> validate_length(:note, max: 500)
        |> check(&unique(&1, :slug, query: Project, repo: ctx.repo, scope: [org_id: ctx.actor.org_id]))
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
        query = Keyword.fetch!(opts, :query)
        scope = Keyword.get(opts, :scope, [])

        if query |> where(^([{field, value}] ++ scope)) |> repo.exists?() do
          Ecto.Changeset.add_error(changeset, field, "has already been taken",
            validation: :unique
          )
        else
          changeset
        end
    end
  end
end
