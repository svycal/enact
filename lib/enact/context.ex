defmodule Enact.Context do
  @moduledoc """
  The per-invocation context threaded through every pipeline step.

    * `actor` — required, from opts; opaque to Enact (struct, scope, or
      `:anonymous`) — only the host app's `authorize/1` and fetchers read it
    * `subject` — filled by the load step: the updated record (patch mode)
      or the parent anchor (create-under-parent)
    * `params` — caller params after key stringification (values still
      raw), kept for presence checks (`Enact.provided?/2`) and audit
    * `repo` — the injected repo module
    * `mode` — `:create` or `:patch`, from the action's `config/0`
    * `assigns` — caller-passed metadata merged with resolver-stashed
      references (resolver keys win on collision)
  """

  defstruct [:actor, :subject, :params, :repo, :mode, assigns: %{}]

  @type t :: %__MODULE__{
          actor: term(),
          subject: struct() | nil,
          params: map(),
          repo: module(),
          mode: :create | :patch,
          assigns: map()
        }
end
