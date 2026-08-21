defmodule Enact.Error do
  @moduledoc """
  The closed error taxonomy for action results.

  Every failed `Enact.run/3`, `Enact.dry_run/3`, `Enact.subject/3`, or
  `Enact.authorized/3` returns
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

  `reason` is a stable term for logs, telemetry, and the host renderer.
  Do not echo it wholesale in responses. The default renderer maps `type`
  to generic copy. To vary the message — usually on `:forbidden` — match
  a host-owned reason in the renderer and keep the generic clause as
  fallback. Store atoms, not user-facing strings. Do not use `:not_found`
  reasons to distinguish "exists" from "not yours".

  `meta` is for machine-readable extras (`retry_after`, stable error codes).

  Actions never invent bespoke error *types* — the closed taxonomy means
  the host app's renderer never grows a default clause for `type`.
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

  @doc """
  Builds a `:forbidden` error with an optional reason.

  The runner produces this from `authorize/1`: `false` yields no reason;
  `{:error, reason}` stores that reason. Use a host-owned atom when the
  renderer should vary the 403 copy. Do not echo `reason` wholesale.
  """
  @spec forbidden(term()) :: t()
  def forbidden(reason \\ nil), do: %__MODULE__{type: :forbidden, reason: reason}

  @doc "Builds a `:not_found` error with an optional reason."
  @spec not_found(term()) :: t()
  def not_found(reason \\ nil), do: %__MODULE__{type: :not_found, reason: reason}

  @doc "Builds a `:conflict` error with an optional reason and meta."
  @spec conflict(term(), map()) :: t()
  def conflict(reason \\ nil, meta \\ %{}),
    do: %__MODULE__{type: :conflict, reason: reason, meta: meta}

  @doc "Builds an `:internal` error with a reason for logs and telemetry."
  @spec internal(term()) :: t()
  def internal(reason), do: %__MODULE__{type: :internal, reason: reason}
end
