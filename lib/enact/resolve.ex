defmodule Enact.Resolve do
  @moduledoc """
  Reference resolution — the pipeline step that turns payload references
  (public-facing IDs like `usr_XXXX`) into loaded records.

  Actions declare resolvers as data:

      def resolvers do
        [
          # scalar
          owner: {:owner_id, &fetch_owner/2},
          # path form → batch (one level deep)
          milestone_owners: {[:milestones, :owner_id], &fetch_milestone_owners/2}
        ]
      end

  Resolution failures are field-level `:invalid` errors (`"not found"` on
  the field), never `:not_found` — 404 belongs to the URL subject, and
  "exists but not yours" must be indistinguishable from "doesn't exist".
  All resolvers run and all failures are collected without
  short-circuiting, tagged `validation: :resolution` so renderers can
  distinguish reference errors from input-format errors without string
  matching.

  ## Scalar fetcher contract

  `(public_id, ctx) -> {:ok, struct} | :error | {:error, message}`

  Skipped when the caller did not provide the field (an untouched
  reference on PATCH survives) and on explicit nil-clears (nothing to
  resolve). A provided reference resolves even when identical to the
  current value: re-resolution is re-authorization, and it keeps the
  execute-side contract total — whenever a non-nil reference appears in
  `Enact.updates/2` output, the resolved record is in `ctx.assigns`. On
  success the struct is stashed under the resolver name; `execute/2`
  reads it there (`ctx.assigns.owner.id`) to translate public → internal
  ids.

  ## Batch fetcher contract (path form)

  `(ids, ctx) -> %{public_id => struct | {:error, message}}`

  The unique non-nil ids across the embed's item changesets are collected
  into one fetcher call (N items ≠ N queries). Ids absent from the result
  map render the generic `"not found"` on the item at its correct index;
  `{:error, message}` values render precise per-item messages. On success
  the lookup map is stashed under the resolver name, keyed by public id —
  the execute-side join is a map read. Paths are one level deep only.

  ## Error precision — the trust-anchor rule

  Collapse is mandatory outside the trust anchor; precision is permitted
  inside it. Missing and wrong-tenant must both produce bare `:error`
  (generic `"not found"`) — if they render differently, probing IDs
  reveals which exist. Precise messages (`{:error, "has been
  deactivated"}`) are for records within the caller's own tenant only.
  Safety comes from check ordering inside the fetcher: scope by the trust
  anchor first; emit precise messages only about records the anchor-scoped
  query returned.
  """

  import Ecto.Changeset

  alias Enact.{Context, Error}

  @generic_message "not found"

  @doc false
  @spec run(keyword(), Ecto.Changeset.t(), Context.t()) ::
          {:ok, Ecto.Changeset.t(), Context.t(), [atom()]} | {:error, Error.t()}
  def run(resolvers, changeset, ctx) do
    {changeset, ctx, resolved} =
      Enum.reduce(resolvers, {changeset, ctx, []}, fn {name, spec}, {changeset, ctx, resolved} ->
        case resolve_one(name, spec, changeset, ctx) do
          {changeset, ctx, true} -> {changeset, ctx, [name | resolved]}
          {changeset, ctx, false} -> {changeset, ctx, resolved}
        end
      end)

    if changeset.valid? do
      {:ok, changeset, ctx, Enum.reverse(resolved)}
    else
      {:error, Error.invalid(changeset)}
    end
  end

  ## Scalar

  defp resolve_one(name, {field, fetcher}, changeset, ctx) when is_atom(field) do
    ensure_field!(changeset, field)

    # presence-gated, not change-gated: on PATCH a reference provided
    # identical to its current value records no change but is still a
    # provided write (it appears in updates), so it must re-resolve
    public_id = if Enact.provided?(ctx, field), do: get_field(changeset, field)

    case public_id do
      nil ->
        {changeset, ctx, false}

      public_id ->
        case fetcher.(public_id, ctx) do
          {:ok, record} ->
            {changeset, assign(ctx, name, record), true}

          :error ->
            {resolution_error(changeset, field, @generic_message), ctx, false}

          {:error, message} ->
            {resolution_error(changeset, field, message), ctx, false}

          other ->
            raise ArgumentError,
                  "the fetcher for resolver #{inspect(name)} must return " <>
                    "{:ok, struct}, :error, or {:error, message}; got: #{inspect(other)}"
        end
    end
  end

  ## Batch (path form, one level deep)

  defp resolve_one(name, {[embed_field, item_field], fetcher}, changeset, ctx) do
    ensure_embed_many!(changeset, embed_field)

    case get_change(changeset, embed_field) do
      nil ->
        {changeset, ctx, false}

      items when is_list(items) ->
        ids =
          items
          |> Enum.map(&get_change(&1, item_field))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        resolve_batch(name, changeset, ctx, embed_field, item_field, items, ids, fetcher)
    end
  end

  defp resolve_one(name, {path, _fetcher}, _changeset, _ctx) when is_list(path) do
    raise ArgumentError,
          "resolver #{inspect(name)} uses path #{inspect(path)} — resolver paths " <>
            "are one level deep only ([embed_field, item_field]); deeper nesting " <>
            "is an API-shape smell"
  end

  defp resolve_batch(_name, changeset, ctx, _embed_field, _item_field, _items, [], _fetcher) do
    {changeset, ctx, false}
  end

  defp resolve_batch(name, changeset, ctx, embed_field, item_field, items, ids, fetcher) do
    results = fetcher.(ids, ctx)

    unless is_map(results) do
      raise ArgumentError,
            "the fetcher for resolver #{inspect(name)} must return a map of " <>
              "%{public_id => struct | {:error, message}}; got: #{inspect(results)}"
    end

    {items, errored?} =
      Enum.map_reduce(items, false, fn item, errored? ->
        case get_change(item, item_field) do
          nil ->
            {item, errored?}

          id ->
            case Map.get(results, id, :__absent__) do
              :__absent__ -> {resolution_error(item, item_field, @generic_message), true}
              {:error, message} -> {resolution_error(item, item_field, message), true}
              _record -> {item, errored?}
            end
        end
      end)

    if errored? do
      # splice the errored item changesets back into the parent's changes and
      # explicitly mark the parent invalid — the changes-map surgery alone
      # doesn't propagate item validity
      changeset = %{
        changeset
        | changes: Map.put(changeset.changes, embed_field, items),
          valid?: false
      }

      {changeset, ctx, false}
    else
      {changeset, assign(ctx, name, results), true}
    end
  end

  ## Helpers

  defp assign(ctx, name, value), do: %{ctx | assigns: Map.put(ctx.assigns, name, value)}

  defp resolution_error(changeset, field, message) do
    add_error(changeset, field, message, validation: :resolution)
  end

  defp ensure_embed_many!(changeset, field) do
    ensure_field!(changeset, field)

    case Map.get(changeset.types, field) do
      {:embed, %{cardinality: :many}} ->
        :ok

      _other ->
        raise ArgumentError,
              "path-form resolver references #{inspect(field)}, which is not an " <>
                "embeds_many field — batch resolution runs over the item changesets " <>
                "of an embeds_many; use the scalar form ({field, fetcher}) for " <>
                "scalar references"
    end
  end

  defp ensure_field!(changeset, field) do
    unless Map.has_key?(changeset.types, field) do
      schema =
        case changeset.data do
          %module{} -> inspect(module)
          _ -> "the input schema (this action has input: nil)"
        end

      raise ArgumentError,
            "resolver references field #{inspect(field)}, which does not exist on " <>
              "#{schema} — resolver fields must be castable input-schema fields"
    end
  end
end
