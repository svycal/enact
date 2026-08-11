defmodule Enact.Error do
  @moduledoc """
  The closed error taxonomy for action results.

  Every failed `Enact.run/3` or `Enact.dry_run/3` returns
  `{:error, %Enact.Error{}}` with one of five types, each mapping to an
  HTTP status:

    * `:invalid` → 422 — bad input; carries the changeset (the only
      outward-rich type; it describes the caller's own input)
    * `:forbidden` → 403 — the actor may not perform this action
    * `:not_found` → 404 — the URL-anchored subject does not exist
      (or is outside the caller's tenant)
    * `:conflict` → 409 — input was fine; the world changed
      (optimistic/temporal races, confirmation-digest mismatch)
    * `:internal` → 500 — a bug bucket; every production occurrence is
      either a bug or a missing promotion to a real type

  `reason` is internal only (logs/telemetry) and must never be serialized
  to callers. `meta` is for machine-readable extras (retry_after, stable
  error codes) only.

  Actions never invent bespoke error atoms — the closed taxonomy means the
  host app's renderer never grows a default clause.
  """

  defstruct [:type, :changeset, :reason, meta: %{}]

  @type type :: :invalid | :forbidden | :not_found | :conflict | :internal

  @type t :: %__MODULE__{
          type: type(),
          changeset: Ecto.Changeset.t() | nil,
          reason: term(),
          meta: map()
        }

  @doc "Builds an `:invalid` error carrying the changeset."
  @spec invalid(Ecto.Changeset.t()) :: t()
  def invalid(%Ecto.Changeset{} = changeset),
    do: %__MODULE__{type: :invalid, changeset: changeset}

  @doc "Builds a `:forbidden` error with an optional internal reason."
  @spec forbidden(term()) :: t()
  def forbidden(reason \\ nil), do: %__MODULE__{type: :forbidden, reason: reason}

  @doc "Builds a `:not_found` error with an optional internal reason."
  @spec not_found(term()) :: t()
  def not_found(reason \\ nil), do: %__MODULE__{type: :not_found, reason: reason}

  @doc "Builds a `:conflict` error with an optional internal reason and meta."
  @spec conflict(term(), map()) :: t()
  def conflict(reason \\ nil, meta \\ %{}),
    do: %__MODULE__{type: :conflict, reason: reason, meta: meta}

  @doc "Builds an `:internal` error with the internal reason."
  @spec internal(term()) :: t()
  def internal(reason), do: %__MODULE__{type: :internal, reason: reason}
end
