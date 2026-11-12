defmodule Enact.EmbeddedInputSchema do
  @moduledoc """
  Setup for nested item schemas: the modules an input schema embeds
  with `embeds_one` or `embeds_many`.

  `use Enact.EmbeddedInputSchema` imports
  `Enact.InputSchema.cast_input/4` and accepts the `:partial` option.
  `use Ecto.Schema`, `import Ecto.Changeset`, and `@primary_key false`
  stay explicit in the module.

  An item schema implements Ecto's `changeset/2`, which `cast_embed`
  invokes. It does not implement `changeset/3` or `fields/1`; those
  belong to top-level input modules (`Enact.InputSchema`).

  An item schema that is not partial can take the bare
  `import Enact.InputSchema` instead.

  ## Partial embeds

  An embed replaces the stored object wholesale by default. To accept
  partial objects, pass `partial: true`:

      defmodule MyApp.Scheduling.Inputs.BookingPolicyInput do
        use Ecto.Schema
        use Enact.EmbeddedInputSchema, partial: true

        @primary_key false
        embedded_schema do
          field :allow_booking, :boolean
          field :allow_reschedule, :boolean
        end

        def changeset(item, params) do
          cast_input(item, params, [:allow_booking, :allow_reschedule])
        end
      end

  For a partial embed:

    * `Enact.updates/2` keeps only the sub-keys the caller provided. An
      explicitly-null sub-key is present as `nil`. An omitted sub-key is
      absent. An object with no provided sub-keys (`{}`, or only
      undeclared keys) is absent from the updates map.
    * `Enact.merged/4` builds the object to persist: the caller's value
      for each provided sub-key and the subject's current value for the
      rest. Call it in `execute/2`, and in `validate/2` for rules about
      the merged result.

  Validations in the item schema see the partially-cast object, so do
  not call `validate_required` there.

  ### Nesting

  Each module passes `partial: true` for itself, and `Enact.updates/2`
  and `Enact.merged/4` apply the declaration at every depth. A partial
  embed does not depend on the embed that contains it:

    * Inside a partial embed, both levels merge.
    * Inside a replace-wholesale `embeds_one`, the outer object is
      replaced and the partial embed merges over the stored value at the
      same path. If the caller sends the outer object without the
      partial embed, the partial embed is cleared with the rest.

  The declaration has no effect inside an `embeds_many`. Array items
  have no identity to merge by, so each item is replaced wholesale,
  including the embeds inside it.

  The declaration applies to every field that embeds the module. To use
  one shape as partial in one input and wholesale in another, define two
  item modules.
  """

  @doc """
  Sets up an item schema.

  Imports `Enact.InputSchema.cast_input/4` and defines `__enact__/1`,
  which Enact reads to find the declaration.

  Options (anything else raises at compile time):

    * `:partial` — `true` when the embed accepts partial objects.
      Defaults to `false`.
  """
  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, partial: false)
    partial = opts[:partial]

    unless is_boolean(partial) do
      raise ArgumentError,
            "use Enact.EmbeddedInputSchema expects :partial to be true or false, " <>
              "got: #{Macro.to_string(partial)}"
    end

    quote do
      import Enact.InputSchema, only: [cast_input: 3, cast_input: 4]

      @doc false
      def __enact__(:partial), do: unquote(partial)
    end
  end
end
