# Recipes

End-to-end examples of common patterns. The samples follow the documented conventions: context-scoped module layout, private fetchers dispatching to context functions, and presence-preserving handling of `Enact.updates/2` output.

## 1. Embedded data end-to-end

An order with line items: nested input casting, per-item validation, batch resolution of item references, and replace-wholesale persistence. The item schema is defined before the parent, because an alias referenced by `embeds_many` must resolve when the schema block expands.

```elixir
# lib/my_app/orders/inputs/line_item_input.ex
defmodule MyApp.Orders.Inputs.LineItemInput do
  use Ecto.Schema
  import Ecto.Changeset
  # item schemas take the bare import — changeset/2 is invoked by
  # cast_embed, so they do not adopt the behaviour via use
  import Enact.InputSchema, only: [cast_input: 3]

  @primary_key false
  embedded_schema do
    field :product_id, :string
    field :quantity, :integer
  end

  def changeset(item, params) do
    item
    |> cast_input(params, [:product_id, :quantity])
    |> validate_required([:product_id, :quantity])
    |> validate_number(:quantity, greater_than: 0)
  end
end
```

```elixir
# lib/my_app/orders/inputs/order_input.ex
defmodule MyApp.Orders.Inputs.OrderInput do
  use Ecto.Schema
  use Enact.InputSchema
  import Ecto.Changeset

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
  def config, do: [mode: :patch]

  @impl Enact.Action
  def input, do: CustomerInput

  @impl Enact.Action
  def load_subject(%{"id" => id}, ctx), do: Customers.get_customer(ctx.actor, id)

  @impl Enact.Action
  def authorize(ctx), do: MyApp.Policy.can?(ctx.actor, :update, ctx.subject)

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

A two-phase confirmation flow for an agent-facing tool. `preview.updates` is plain atom-keyed data, embeds included, so it JSON-encodes directly. Serialize `preview.subject` for the current side of the diff. The digest, not the serialized display, carries confirmation integrity, so the display format can be reshaped freely.

```elixir
defmodule MyAppWeb.MCP.UpdateProjectTool do
  alias MyApp.Projects

  # Phase 1: no confirmation token → validate fully, reflect back, change nothing
  def call(params, scope) do
    case Projects.update_project_dry_run(params, actor: scope) do
      {:ok, preview} ->
        current =
          preview.subject
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
    case Projects.update_project(params, actor: scope, confirm_digest: confirm_digest) do
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
  use Enact.InputSchema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :name, :string
    field :summary, :string
  end

  @scalars ~w(name summary)a
  # summary is not in @required: on create, omission must be allowed so
  # the column default applies, and validate_required would reject it
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

The emptiness test is trimmed, so `"   "` counts as empty, and the `keep_empty_strings:` disposition stores it as `""` rather than coalescing to `nil`.

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

The cases resolve as follows: `""` persists as `""`; `"   "` counts as empty and persists as `""`; explicit `null` returns a 422 on `:summary`; omitted leaves the field untouched, and create inserts fall to the column default. The drift test in the Testing guide catches any `""`-at-rest field wired with a plain cast.

## 6. Partial updates on a singular embed

The default embed contract is replace-wholesale. For a singular config object — a `booking_policy` with several flags — that forces callers to send the whole object to change one flag. Declaring the embed in the input module's `partial_embeds/1` manifest switches it to partial-object semantics: `Enact.updates/2` filters its sub-keys by presence, so the updates map, previews, and confirmation digests carry exactly what the caller sent, one level down. (`embeds_many` cannot be declared partial — merging arrays requires item identity, which is a different contract; the guardrails enforce this.)

```json
PATCH { "booking_policy": { "allow_booking": false } }
```

The item schema stays shape-only. Partial sends cast over an empty struct, so `validate_required` here would wrongly reject them:

```elixir
# lib/my_app/scheduling/inputs/booking_policy_input.ex
defmodule MyApp.Scheduling.Inputs.BookingPolicyInput do
  use Ecto.Schema
  import Enact.InputSchema, only: [cast_input: 3]

  @primary_key false
  embedded_schema do
    field :allow_booking, :boolean
    field :allow_reschedule, :boolean
  end

  def changeset(item, params) do
    cast_input(item, params, [:allow_booking, :allow_reschedule])
  end
end
```

```elixir
# lib/my_app/scheduling/inputs/link_input.ex
defmodule MyApp.Scheduling.Inputs.LinkInput do
  use Ecto.Schema
  use Enact.InputSchema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :name, :string
    embeds_one :booking_policy, MyApp.Scheduling.Inputs.BookingPolicyInput
  end

  @impl Enact.InputSchema
  def changeset(base, params, _mode) do
    base
    |> cast_input(params, [:name])
    |> cast_embed(:booking_policy)
  end

  @impl Enact.InputSchema
  def fields(_mode), do: [:name, :booking_policy]

  @impl Enact.InputSchema
  def from_subject(link), do: %__MODULE__{name: link.name}

  @impl Enact.InputSchema
  def partial_embeds(_mode), do: [:booking_policy]
end
```

`execute/2` merges the partial object over the current value using `Enact.merged/4` — the same function merged-result validations use, so the merge semantics have one definition:

```elixir
@impl Enact.Action
def execute(changeset, ctx) do
  updates =
    changeset
    |> Enact.updates(ctx)
    |> merge_booking_policy(changeset, ctx)

  ctx.subject
  |> Link.changeset(updates)
  |> ctx.repo.update()
end

defp merge_booking_policy(updates, changeset, ctx) do
  case Map.fetch(updates, :booking_policy) do
    # provided → the result-state view is the merged object
    {:ok, %{}} ->
      %{updates | booking_policy: Enact.merged(changeset, ctx, :booking_policy)}

    # omitted (untouched) or explicit null (clears the whole object)
    _ ->
      updates
  end
end
```

When the policy is stored as flat columns instead of an embed, the merge disappears: provided sub-keys become columns, and omitted columns stay out of the write — untouched by the same presence semantics that protect top-level fields:

```elixir
defp flatten_booking_policy(updates, ctx) do
  case Map.fetch(updates, :booking_policy) do
    {:ok, %{} = partial} ->
      updates
      |> Map.delete(:booking_policy)
      # atoms derive from the input schema's closed field set
      |> Map.merge(Map.new(partial, fn {key, value} -> {:"policy_#{key}", value} end))

    {:ok, nil} ->
      updates
      |> Map.delete(:booking_policy)
      |> Map.merge(%{policy_allow_booking: nil, policy_allow_reschedule: nil})

    :error ->
      updates
  end
end
```

The cases resolve as follows: a provided sub-key merges; an explicitly-null sub-key is present as `nil` and clears that flag; an omitted sub-key is absent and stays untouched; a null for the whole object clears everything. Previews and digests contain exactly the provided sub-keys, so the user confirms the partial change itself.

### Validating the merged result

Validations see the partially-cast object, not the merged result — the base never seeds embeds, so `get_field` on the item changeset returns `nil` for omitted sub-keys. Per-key intrinsic rules (formats, bounds) still work in the item schema, since Ecto validators skip absent and nil changes. But a rule about the *merged* policy belongs in the action's `validate/2`, against the result-state view built by `Enact.merged/4` — the same function the execute merge uses:

```elixir
@impl Enact.Action
def validate(changeset, ctx) do
  policy = Enact.merged(changeset, ctx, :booking_policy)

  if policy.allow_booking or policy.allow_reschedule do
    changeset
  else
    add_error(changeset, :booking_policy, "must keep at least one option enabled")
  end
end
```

`merged/4` reads each sub-key from the caller's casted value where provided — including explicit nulls, which correctly read as clears — and from `ctx.subject` where not. The key list derives from the schema by default. See its documentation for the full case table (whole-object nulls, missing current objects).

### Displaying partial changes in a confirmation flow

A confirmation preview serves two purposes. The digest binds the delta: the exact change the user confirms. The display provides context: the current and resulting values. Bind the delta; display both. Extending recipe 4's response shape:

```elixir
current = Scheduling.serialize(preview.subject).booking_policy
resulting = Map.merge(current, preview.updates.booking_policy)

%{
  changes: preview.updates,                  # the delta; bound by the digest
  current: %{booking_policy: current},
  resulting: %{booking_policy: resulting},   # display context; not digest-bound
  confirm_digest: preview.digest
}
```

`resulting` is computed against current state, which can change before the confirming run. The design makes no reservation: the confirming run re-validates against current state, and the confirmed delta is what executes.
