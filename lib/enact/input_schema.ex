defmodule Enact.InputSchema do
  @moduledoc """
  The contract for top-level input-schema modules — plain Ecto embedded
  schemas that adopt this behaviour via `use Enact.InputSchema`, which
  sets `@behaviour` and imports `cast_input/4` and nothing more.
  `use Ecto.Schema`, `import Ecto.Changeset`, and `@primary_key false`
  stay explicit in the module. Plain `@behaviour` + `import` remains
  equivalent.

  ## The callbacks

    * `changeset/3` — `(base, params, mode)`; the runner passes the
      action's `config[:mode]` verbatim. Write one head per mode; per-mode
      deltas are data (cast lists / required lists), not conditionals.
    * `fields/1` — the mode-specific castable field list. This is the
      introspection surface (`__schema__(:fields)` cannot distinguish
      create-castable from patch-castable); `Enact.updates/2` key selection
      and host-app reconciliation tests read it.
    * `from_subject/1` — required iff a patch-mode action uses the module;
      create-only modules may omit it.

  ## The validation base

  The `base` argument exists **only** so validations see result-state;
  extraction (`Enact.updates/2`) ignores the changeset's diff entirely and
  keys off presence in raw params. (The system-level walkthrough of how
  base, cast, presence, and extraction interact lives in the
  [Change Detection](change-detection.html) guide.)

  In create mode the base is the empty struct. In patch mode it is
  `from_subject(ctx.subject)` — an explicit, total projection of the loaded
  subject into the input representation (public-ID rendering, renames,
  representation conversions live here and nowhere else). With the base in
  place, `validate_required` and `get_field/2`-based cross-field rules work
  unmodified on PATCH: an omitted-but-populated required field passes, an
  explicit nil-clear fails, and `get_field` returns the value the record
  will have.

  `from_subject/1` must guarantee:

    * **totality over scalar fields** — every scalar field gets a non-nil
      value when the subject has one; a forgotten field silently revives
      the nil-clear-vs-omitted ambiguity for that field (host apps test
      this via projection-completeness, and blind struct-copying like
      `Map.take(subject, fields)` is forbidden as an implementation)
    * **embeds are never seeded** — they stay at structural defaults
      (`[]`/`nil`); array semantics are replace-wholesale, and seeding
      would engage `cast_embed`'s diff-by-identity machinery

  ## Why no field defaults

  Omitted fields are excluded from extraction by presence, so a schema
  default never persists — it would only mislead validations into seeing a
  value the write will not contain. Defaults live in the DB column (or
  persistence schema); `Enact.Guardrails` enforces this.

  ## Nested item schemas

  Deliberate asymmetry: nested item modules (invoked by `cast_embed`, not
  the runner) are mode-blind and implement Ecto's native `changeset/2` —
  they do not adopt this behaviour. They take the bare
  `import Enact.InputSchema` and still cast with `cast_input/4`, since
  item fields have the same empty-string concerns as top-level fields. If
  an item schema is later promoted to a top-level input for some action,
  it gains a `changeset/3` alongside its `changeset/2` — same module,
  both contracts, no conflict.

  ## Casting

  `cast_input/4`, defined on this module and imported by input modules, is
  the casting entry for scalar fields: `Ecto.Changeset.cast/4` with JSON
  API empty-string semantics derived from field types. See its
  documentation for the exact behavior table.
  """

  @callback changeset(base :: struct(), params :: map(), mode :: atom()) :: Ecto.Changeset.t()
  @callback fields(mode :: atom()) :: [atom()]
  @callback from_subject(subject :: struct()) :: struct()

  @optional_callbacks from_subject: 1

  @doc """
  Adopts the contract. Expands to exactly:

      @behaviour Enact.InputSchema
      import Enact.InputSchema, only: [cast_input: 3, cast_input: 4]

  and will never inject more — `use Ecto.Schema`, `import Ecto.Changeset`,
  and `@primary_key false` stay explicit in the module.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Enact.InputSchema
      import Enact.InputSchema, only: [cast_input: 3, cast_input: 4]
    end
  end

  @doc """
  Casts scalar params with JSON API semantics.

  A replacement for `Ecto.Changeset.cast/4` in input-module changeset
  heads. Ecto's stock cast implements HTML-form semantics: `""` on any
  field means "no value" and silently becomes `nil`, regardless of field
  type. `cast_input/4` derives empty-string handling from each field's
  schema type instead:

  | Input            | Non-string field         | `:string` field       | `:string` in `keep_empty_strings:` |
  | ---------------- | ------------------------ | --------------------- | ---------------------------------- |
  | `"5"`, `"true"`  | coerced via `Ecto.Type`  | value, trimmed        | value, trimmed                     |
  | `""`, `"   "`    | `"is invalid"` error     | `nil` (empty → clear) | `""` (empty is a value)            |
  | `null`           | `nil`                    | `nil`                 | `nil`                              |
  | omitted          | untouched                | untouched             | untouched                          |

  Options (a closed set — anything else raises):

    * `:keep_empty_strings` — `:string` fields whose empty disposition is
      `""` rather than `nil`, for `NOT NULL DEFAULT ''` columns where the
      empty string is a value
    * `:trim_except` — `:string` fields whose whitespace is significant
      (passwords, for example); these are not trimmed, and only a literal
      `""` counts as empty for them

  Option fields must be `:string` fields on the schema; listing a field
  outside a given head's cast list is allowed and inert, so option
  attributes can be shared across mode heads with differing cast lists.

  Normalization applies only to fields whose schema type is literally
  `:string` and whose param value is a binary; custom types receive the
  raw value and apply their own `cast/1`. `:binary` fields are never
  trimmed and keep `""` as a value (it is a valid binary). Array fields
  are untouched: elements are neither trimmed, coalesced, nor dropped —
  a `""` element in an `{:array, :string}` field passes through, so
  validate against empty elements where they matter. Embed fields are not
  accepted — cast them with `Ecto.Changeset.cast_embed/3` as usual.
  Presence semantics are unchanged: normalization rewrites values, never
  adds or removes keys, so an empty string coalescing to `nil` still
  records a presence-visible nil-clear.

  Because `validate_required/2` consults the cast's `empty_values`, a
  literal `""` value satisfies required-ness after `cast_input/4`. For
  plain `:string` fields this changes nothing (empties are already `nil`
  before validation); for `keep_empty_strings:` fields it means
  `validate_required` expresses "never nil, `""` allowed".

  Required-ness, defaults, and null-rejection are out of scope; they stay
  in changeset heads, DB columns, and action `validate/2` respectively.
  `Enact.Test.assert_rejects_empty_strings/3` verifies the empty-string
  outcome regardless of whether a module uses `cast_input/4` or a stock
  `cast` with `empty_values: []`.
  """
  @spec cast_input(struct() | Ecto.Changeset.t(), map(), [atom()], keyword()) ::
          Ecto.Changeset.t()
  def cast_input(base_or_changeset, params, fields, opts \\ [])
      when is_map(params) and is_list(fields) do
    opts = Keyword.validate!(opts, keep_empty_strings: [], trim_except: [])
    keep_empty = opts[:keep_empty_strings]
    trim_except = opts[:trim_except]

    module = schema_module!(base_or_changeset)
    validate_string_fields!(keep_empty, ":keep_empty_strings", module, fields)
    validate_string_fields!(trim_except, ":trim_except", module, fields)

    params = normalize_strings(params, module, fields, keep_empty, trim_except)

    Ecto.Changeset.cast(base_or_changeset, params, fields, empty_values: [])
  end

  defp schema_module!(%Ecto.Changeset{data: %module{}}), do: ensure_schema!(module)

  defp schema_module!(%Ecto.Changeset{} = changeset) do
    raise ArgumentError,
          "cast_input/4 requires a changeset over an input-schema struct; " <>
            "schemaless changesets are not supported (got data: #{inspect(changeset.data)})"
  end

  defp schema_module!(%module{}), do: ensure_schema!(module)

  defp schema_module!(other) do
    raise ArgumentError,
          "cast_input/4 expects an input-schema struct or changeset; got: #{inspect(other)}"
  end

  defp ensure_schema!(module) do
    unless function_exported?(module, :__schema__, 2) do
      raise ArgumentError,
            "cast_input/4 expects an Ecto embedded schema; #{inspect(module)} is not one"
    end

    module
  end

  # schema-level check only: a listed field absent from this head's cast
  # list is inert, so option attributes can be shared across mode heads
  # with differing cast lists
  defp validate_string_fields!(list, opt_name, module, _fields) do
    Enum.each(list, fn field ->
      case module.__schema__(:type, field) do
        :string ->
          :ok

        nil ->
          raise ArgumentError,
                "#{opt_name} lists #{inspect(field)}, which does not exist on " <>
                  inspect(module)

        _other ->
          raise ArgumentError,
                "#{opt_name} lists #{inspect(field)}, which is not a :string field on " <>
                  inspect(module)
      end
    end)
  end

  defp normalize_strings(params, module, fields, keep_empty, trim_except) do
    Enum.reduce(fields, params, fn field, params ->
      with :string <- module.__schema__(:type, field),
           {:ok, key, value} <- fetch_param(params, field),
           true <- is_binary(value) do
        Map.put(params, key, normalize_string(value, field, keep_empty, trim_except))
      else
        _ -> params
      end
    end)
  end

  defp fetch_param(params, field) do
    string_key = Atom.to_string(field)

    cond do
      Map.has_key?(params, field) -> {:ok, field, Map.get(params, field)}
      Map.has_key?(params, string_key) -> {:ok, string_key, Map.get(params, string_key)}
      true -> :error
    end
  end

  defp normalize_string(value, field, keep_empty, trim_except) do
    value = if field in trim_except, do: value, else: String.trim(value)

    cond do
      value != "" -> value
      field in keep_empty -> ""
      true -> nil
    end
  end
end
