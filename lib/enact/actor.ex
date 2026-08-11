defprotocol Enact.Actor do
  @moduledoc """
  Answers `anonymous?/1` for any actor term.

  Anonymity must be a pattern-matchable value, never an absence —
  `actor: nil` always raises in the runner. The fallback impl returns
  `false` for any term, so authenticated actors need no impl at all.

  Two ways to represent an anonymous caller:

    * the bare `:anonymous` atom — zero-ceremony option for simple apps
    * a host-app impl for a scope struct (`%Scope{user: nil} → true`),
      enabling rich anonymous scopes carrying session id / IP for rate
      limiting — the idiomatic Phoenix 1.8 shape

  An anonymous actor is only permitted by actions declaring
  `anonymous?: true` in `config/0`; the runner rejects it with
  `:forbidden` everywhere else, before any pipeline work.
  """

  @fallback_to_any true

  @spec anonymous?(t) :: boolean()
  def anonymous?(actor)
end

defimpl Enact.Actor, for: Any do
  def anonymous?(_actor), do: false
end

defimpl Enact.Actor, for: Atom do
  def anonymous?(:anonymous), do: true
  def anonymous?(_atom), do: false
end
