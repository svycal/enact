defmodule Enact.Preview do
  @moduledoc """
  The result of `Enact.dry_run/3` — a distinct struct so callers are
  structurally unable to confuse "validated" with "executed".

    * `updates` — `Enact.updates/2` output: the canonical, post-
      normalization "what will be persisted" map. What the user confirms
      is definitionally what executes. Patch previews carry only the
      provided keys; host apps render old → new diffs by comparing against
      the subject.
    * `resolved` — names of resolvers that succeeded. Never the loaded
      structs — those stay in `ctx.assigns` and never reach the caller.
    * `digest` — canonical hash binding the action, mode, and updates
      map, for the confirmation flow: pass it back as `confirm_digest:`
      to `Enact.run/3`, which recomputes post-validation and returns
      `:conflict` on mismatch.

  A preview is not a promise: no reservation semantics. The confirming
  `run/3` re-executes the full pipeline, and races surface as
  `:invalid`/`:conflict` normally.
  """

  defstruct [:action, :mode, :updates, :resolved, :digest]

  @type t :: %__MODULE__{
          action: module(),
          mode: :create | :patch,
          updates: map(),
          resolved: [atom()],
          digest: String.t()
        }

  @doc """
  Canonically digests a pending change: `"sha256:..."` over the action
  module, mode, and updates map together. Folding the action and mode in
  makes "the user confirmed *this exact change*" total — a digest minted
  for one action (or mode) never confirms another, and input-less actions
  (whose updates are always `%{}`) don't collapse to one shared digest.

  The encoding is hand-rolled and injective — every node is type-tagged,
  binaries and atom names are length-prefixed, and map entries are sorted
  by encoded key at every depth. Elixir map ordering alone is not
  sufficient (large maps enumerate in hash order), and the encoding avoids
  `term_to_binary`, whose bytes are not guaranteed stable across OTP
  releases — digests must survive the confirmation gap in a mixed-version
  rolling deploy.
  """
  @spec digest(module(), :create | :patch, map()) :: String.t()
  def digest(action, mode, updates)
      when is_atom(action) and is_atom(mode) and is_map(updates) do
    "sha256:" <>
      Base.encode16(:crypto.hash(:sha256, encode({action, mode, updates})), case: :lower)
  end

  defp encode(%module{} = struct),
    do: ["S<", encode_atom(module), encode_entries(Map.from_struct(struct)), ">"]

  defp encode(map) when is_map(map), do: ["M<", encode_entries(map), ">"]
  defp encode(list) when is_list(list), do: ["L<", Enum.map(list, &encode/1), ">"]

  defp encode(tuple) when is_tuple(tuple),
    do: ["T<", tuple |> Tuple.to_list() |> Enum.map(&encode/1), ">"]

  defp encode(binary) when is_binary(binary),
    do: ["B", Integer.to_string(byte_size(binary)), ":", binary]

  defp encode(atom) when is_atom(atom), do: encode_atom(atom)
  defp encode(int) when is_integer(int), do: ["I", Integer.to_string(int), ";"]

  defp encode(float) when is_float(float),
    do: ["F", :erlang.float_to_binary(float, [:short]), ";"]

  defp encode(other), do: ["X", inspect(other, limit: :infinity), ";"]

  defp encode_atom(atom) do
    name = Atom.to_string(atom)
    ["A", Integer.to_string(byte_size(name)), ":", name]
  end

  defp encode_entries(map) do
    map
    |> Enum.map(fn {key, value} -> {IO.iodata_to_binary(encode(key)), encode(value)} end)
    |> Enum.sort_by(fn {key_bytes, _value} -> key_bytes end)
    |> Enum.map(fn {key_bytes, value_iodata} -> [key_bytes, value_iodata] end)
  end
end
