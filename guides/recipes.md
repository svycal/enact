# Recipes

End-to-end examples of common patterns. The samples follow the documented conventions: context-scoped module layout, private fetchers dispatching to context functions, and presence-preserving handling of `Enact.updates/2` output.

## 1. Embedded data end-to-end

An order with line items: nested input casting, per-item validation, batch resolution of item references, and replace-wholesale persistence. The item schema is defined before the parent, because an alias referenced by `embeds_many` must resolve when the schema block expands.

```elixir
# lib/my_app/orders/inputs/line_item_input.ex
defmodule MyApp.Orders.Inputs.LineItemInput do
  use Ecto.Schema
  import Ecto.Changeset

  # item schema: changeset/2, invoked by cast_embed — no @behaviour
  @primary_key false
  embedded_schema do
    field :product_id, :string
    field :quantity, :integer
  end

  def changeset(item, params) do
    item
    |> cast(params, [:product_id, :quantity])
    |> validate_required([:product_id, :quantity])
    |> validate_number(:quantity, greater_than: 0)
  end
end
```

```elixir
# lib/my_app/orders/inputs/order_input.ex
defmodule MyApp.Orders.Inputs.OrderInput do
  use Ecto.Schema
  import Ecto.Changeset
  import Enact.InputSchema, only: [cast_input: 3]

  @behaviour Enact.InputSchema

  @primary_key false
  embedded_schema do
    field :note, :string
    embeds_many :items, MyApp.Orders.Inputs.LineItemInput
  end

  @impl Enact.InputSchema
  def changeset(base, params, :create) do
    base
    |> cast_input(params, [:note])
    |> cast_embed(:items, required: true)
  end

  @impl Enact.InputSchema
  def fields(:create), do: [:note, :items]
end
```

```elixir
# lib/my_app/orders/actions/create_order.ex
defmodule MyApp.Orders.Actions.CreateOrder do
  use Enact.Action

  alias MyApp.Catalog
  alias MyApp.Orders.Inputs.OrderInput
  alias MyApp.Orders.Order

  @impl Enact.Action
  def input, do: OrderInput

  @impl Enact.Action
  def authorize(ctx), do: MyApp.Policy.can?(ctx.actor, :create_order)

  @impl Enact.Action
  def resolvers do
    [products: {[:items, :product_id], &fetch_products/2}]
  end

  @impl Enact.Action
  def execute(changeset, ctx) do
    updates = Enact.updates(changeset, ctx)
    products = ctx.assigns.products

    # items arrive as plain maps; swap public IDs for internal foreign keys
    # by reading the batch lookup map
    items =
      Enum.map(updates.items, fn item ->
        %{item | product_id: products[item.product_id].id}
      end)

    %Order{org_id: ctx.actor.org.id}
    |> Order.changeset(%{updates | items: items})
    |> ctx.repo.insert()
  end

  # one query for all unique IDs; scoped by the trust anchor first, and
  # precise messages only for records the scoped query returned
  defp fetch_products(public_ids, ctx) do
    ctx.actor
    |> Catalog.get_products_by_public_ids(public_ids)
    |> Map.new(fn product ->
      value = if product.active?, do: product, else: {:error, "is no longer available"}
      {product.public_id, value}
    end)
  end
end
```

An unknown or cross-tenant `product_id` is absent from the fetcher's result map and renders the generic `"not found"` at the correct item index. A deactivated product in the caller's own tenant renders the precise message. Both arrive as ordinary 422 field errors.

## 2. Flattening an embed into columns

The API models an address as a nested object; the table stores flat columns. The translation lives in `execute/2`, and each of the three presence cases (omitted, explicit `null`, provided) must be handled:

```elixir
# lib/my_app/customers/actions/update_customer.ex
defmodule MyApp.Customers.Actions.UpdateCustomer do
  use Enact.Action

  alias MyApp.Customers
  alias MyApp.Customers.Customer
  alias MyApp.Customers.Inputs.CustomerInput

  @impl Enact.Action
  def config, do: [mode: :patch, loads_subject?: true]

  @impl Enact.Action
  def input, do: CustomerInput

  @impl Enact.Action
  def load(%{"id" => id}, ctx), do: Customers.get_customer(ctx.actor, id)

  @impl Enact.Action
  def execute(changeset, ctx) do
    updates =
      changeset
      |> Enact.updates(ctx)
      |> flatten_address()

    ctx.subject
    |> Customer.changeset(updates)
    |> ctx.repo.update()
  end

  @address_columns ~w(address_line1 address_city address_postal_code)a

  defp flatten_address(updates) do
    case Map.fetch(updates, :address) do
      # omitted → columns untouched
      :error ->
        updates

      # explicit null → clear every column
      {:ok, nil} ->
        updates
        |> Map.delete(:address)
        |> Map.merge(Map.from_keys(@address_columns, nil))

      # provided → the embed arrives as a plain map; spread it
      {:ok, address} ->
        updates
        |> Map.delete(:address)
        |> Map.merge(%{
          address_line1: address.line1,
          address_city: address.city,
          address_postal_code: address.postal_code
        })
    end
  end
end
```

Use `Map.fetch/2`, not `Map.get/2`. `Map.get` returns `nil` for both "omitted" and "explicit null", collapsing two cases that must map differently. In the input module, `from_subject/1` leaves the `address` embed unseeded; a validation that needs the current address reads `ctx.subject` directly.

## 3. Reading resolver assigns in `execute/2`

The scalar counterpart of recipe 1's batch lookup. Resolution is presence-gated, so whenever a non-nil reference appears in updates, the resolved record is present in `ctx.assigns`. Handle the three presence cases explicitly:

```elixir
@impl Enact.Action
def resolvers do
  [owner: {:owner_id, &fetch_owner/2}]
end

@impl Enact.Action
def execute(changeset, ctx) do
  updates =
    changeset
    |> Enact.updates(ctx)
    |> translate_owner(ctx)

  ctx.subject
  |> Project.changeset(updates)
  |> ctx.repo.update()
end

defp translate_owner(updates, ctx) do
  case Map.fetch(updates, :owner_id) do
    # omitted → untouched
    :error -> updates
    # explicit null → the foreign key clears; nil passes through
    {:ok, nil} -> updates
    # provided → resolved and re-authorized; swap public ID for internal
    {:ok, _public_id} -> %{updates | owner_id: ctx.assigns.owner.id}
  end
end

defp fetch_owner(public_id, ctx) do
  case MyApp.Accounts.get_org_user(ctx.actor, public_id) do
    nil -> :error
    user -> {:ok, user}
  end
end
```

## 4. Dry-run previews in an MCP response

A two-phase confirmation flow for an agent-facing tool. `preview.updates` is plain atom-keyed data, embeds included, so it JSON-encodes directly. The digest, not the serialized display, carries confirmation integrity, so the display format can be reshaped freely.

```elixir
defmodule MyAppWeb.MCP.UpdateProjectTool do
  alias MyApp.Projects
  alias MyApp.Projects.Actions.UpdateProject

  # Phase 1: no confirmation token → validate fully, reflect back, change nothing
  def call(params, scope) do
    case Enact.dry_run(UpdateProject, params, actor: scope) do
      {:ok, preview} ->
        # old → new diff: the host owns reads, so fetch current values directly
        current =
          Projects.get_project(scope, params["id"])
          |> Projects.serialize()
          |> Map.take(Map.keys(preview.updates))

        %{
          status: "needs_confirmation",
          changes: preview.updates,
          current: current,
          # resolver names only — loaded records never reach the agent; if
          # the UI needs display info, render it host-side from your own reads
          resolved: preview.resolved,
          confirm_digest: preview.digest
        }

      {:error, error} ->
        render_error(error)
    end
  end

  # Phase 2: same params + the digest → execute
  def call(params, scope, confirm_digest) do
    case Enact.run(UpdateProject, params, actor: scope, confirm_digest: confirm_digest) do
      {:ok, project} ->
        %{status: "done", project: Projects.serialize(project)}

      {:error, %Enact.Error{type: :conflict}} ->
        %{status: "stale", message: "The change no longer matches what was confirmed. Preview again."}

      {:error, error} ->
        render_error(error)
    end
  end
end
```

The full pipeline runs again on confirm — authorization, validation, resolution — so a digest match with changed world state still surfaces `:invalid` or `:not_found` normally. The digest only guards against the change itself differing between preview and confirm; it binds the action, mode, and updates map. Both phases emit separate telemetry events, so audit trails count previews and executions separately.

## 5. Empty-string-at-rest columns

Most optional text should be nullable at rest, with `NULL` as the single representation of empty; those fields need none of the following (see the column convention in the Change Detection guide). On a `NOT NULL DEFAULT ''` column, however, `""` is a valid value, and default cast behavior converts it to `nil`, which violates the NOT NULL constraint at persistence. The pattern: declare the exception in `cast_input/4`'s `keep_empty_strings:` option, and reject explicit null in the action.

```elixir
# lib/my_app/customers/inputs/customer_input.ex
defmodule MyApp.Customers.Inputs.CustomerInput do
  use Ecto.Schema
  import Ecto.Changeset
  import Enact.InputSchema, only: [cast_input: 4]

  @behaviour Enact.InputSchema

  @primary_key false
  embedded_schema do
    field :name, :string
    field :summary, :string
  end

  @scalars ~w(name summary)a
  # summary is not in @required: validate_required treats "" as blank,
  # but "" is a valid value for this field
  @required ~w(name)a

  # NOT NULL DEFAULT '' columns: "" is a value, so empties must survive
  # casting instead of coalescing to nil
  @empty_string_text ~w(summary)a

  @impl Enact.InputSchema
  def changeset(base, params, :create) do
    base
    |> cast_input(params, @scalars, keep_empty_strings: @empty_string_text)
    |> validate_required(@required)
  end

  # the :patch head applies the same cast; from_subject/1 projects the
  # stored value (possibly "") like any other scalar
end
```

`cast_input/4` handles the whitespace normalization: `"   "` trims to `""`, which the `keep_empty_strings:` disposition keeps as the value rather than coalescing to `nil`.

Explicit null is the remaining case. The field must never be null but may be blank, which `validate_required` cannot express: it rejects both `nil` and blank strings. Only presence distinguishes "omitted" (allowed — the column default applies) from "explicit null" (an error), so the rule lives in the action's `validate/2`:

```elixir
@impl Enact.Action
def validate(changeset, ctx) do
  if Enact.provided?(ctx, :summary) and is_nil(get_field(changeset, :summary)) do
    add_error(changeset, :summary, "can't be null")
  else
    changeset
  end
end
```

The cases resolve as follows: `""` persists as `""`; `"   "` trims to `""`; explicit `null` returns a 422 on `:summary`; omitted leaves the field untouched, and create inserts fall to the column default. The drift test in the Testing guide catches any `""`-at-rest field wired with a plain cast.
