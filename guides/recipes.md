# Recipes

Worked, end-to-end examples of the patterns that come up in real actions. Every sample follows the documented conventions — context-scoped module layout, private fetchers dispatching to context functions, presence-faithful handling of `Enact.updates/2` output — so they can serve as precedent, not just illustration.

## 1. Embedded data end-to-end

An order with line items: nested input casting, per-item validation, batch resolution of item references, and replace-wholesale persistence. Note the item schema is defined *before* the parent — an alias referenced by `embeds_many` must already resolve when the schema block expands.

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

  @behaviour Enact.InputSchema

  @primary_key false
  embedded_schema do
    field :note, :string
    embeds_many :items, MyApp.Orders.Inputs.LineItemInput
  end

  @impl Enact.InputSchema
  def changeset(base, params, :create) do
    base
    |> cast(params, [:note])
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

    # items arrive as plain maps; swap public ids for internal FKs —
    # the batch lookup map makes the join a map read per item
    items =
      Enum.map(updates.items, fn item ->
        %{item | product_id: products[item.product_id].id}
      end)

    %Order{org_id: ctx.actor.org.id}
    |> Order.changeset(%{updates | items: items})
    |> ctx.repo.insert()
  end

  # one query for all unique ids; scoped by the trust anchor first, and
  # precise messages only about records the scoped query returned
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

An unknown or cross-tenant `product_id` is simply absent from the fetcher's map and renders the generic `"not found"` at the right item index; a deactivated product in the caller's own tenant renders the precise message. Both arrive as ordinary 422 field errors.

## 2. Flattening an embed into columns

The API models an address as a nested object; the table stores flat columns. The input/persistence boundary translation lives in `execute/2` — and the three presence cases (omitted, explicit `null`, provided) must each map faithfully:

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

`Map.fetch/2` (never `Map.get/2`) is what keeps PATCH fidelity through the transform — `Map.get` would collapse "omitted" and "explicit null" into one case. Reminder for the input module: `from_subject/1` still leaves the `address` embed unseeded; a validation that needs the *current* address reads `ctx.subject` directly.

## 3. Reading resolver assigns in `execute/2`

The scalar counterpart of recipe 1's batch join. Because resolution is presence-gated, the contract is total: whenever a non-nil reference appears in updates, the resolved record is in `ctx.assigns` — no defensive `Map.get` needed. The three presence cases still deserve explicit handling:

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
    # explicit null → the FK clears; nil passes through as-is
    {:ok, nil} -> updates
    # provided → resolved and re-authorized; swap public id for internal
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

The two-phase confirmation flow for an agent-facing tool. `preview.updates` is plain atom-keyed data (embeds included), so it JSON-encodes directly; the digest — not your serialization — carries confirmation exactness, so the display shape is free to be lossy or prettified.

```elixir
defmodule MyAppWeb.MCP.UpdateProjectTool do
  alias MyApp.Projects
  alias MyApp.Projects.Actions.UpdateProject

  # Phase 1: no confirmation token → validate fully, reflect back, change nothing
  def call(params, scope) do
    case Enact.dry_run(UpdateProject, params, actor: scope) do
      {:ok, preview} ->
        # old → new diff: the host owns reads, so fetch current values itself
        current =
          Projects.get_project(scope, params["id"])
          |> Projects.serialize()
          |> Map.take(Map.keys(preview.updates))

        %{
          status: "needs_confirmation",
          changes: preview.updates,
          current: current,
          # resolver names only — loaded records never reach the agent;
          # if the UX needs display info ("assigning to Jane Doe"),
          # render it host-side from your own reads
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

The full pipeline re-runs on confirm — authorization, validation, resolution — so a digest match with changed world state still surfaces `:invalid`/`:not_found` normally; the digest only guards against the *change itself* drifting between preview and confirm (it binds action, mode, and the exact updates map). Both phases emit distinct telemetry, so audit trails count previews and executions separately.
