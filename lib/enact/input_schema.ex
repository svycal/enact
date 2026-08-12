defmodule Enact.InputSchema do
  @moduledoc """
  The contract for top-level input-schema modules — plain Ecto embedded
  schemas that declare `@behaviour Enact.InputSchema` (no `use` macro).

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
  they do not declare this behaviour. If an item schema is later promoted
  to a top-level input for some action, it gains a `changeset/3` alongside
  its `changeset/2` — same module, both contracts, no conflict.
  """

  @callback changeset(base :: struct(), params :: map(), mode :: atom()) :: Ecto.Changeset.t()
  @callback fields(mode :: atom()) :: [atom()]
  @callback from_subject(subject :: struct()) :: struct()

  @optional_callbacks from_subject: 1
end
