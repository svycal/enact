# Change Detection

How Enact decides what a write contains — and why the usual Ecto PATCH workarounds (`force_changes:`, subject-fallback reads, manual merge logic) never appear in an Enact codebase.

## The two questions

Every write operation threads two distinct questions through the pipeline, and each has exactly one answering mechanism:

- **"What did the caller say?"** — answered by **presence in raw params**. This drives extraction and persistence, via `Enact.provided?/2` and `Enact.updates/2`.
- **"What is the world?"** — answered by the **validation base**, the struct the changeset is cast over. This drives what validations see. It never drives extraction.

The central rule is that neither mechanism answers the other's question. Extraction that depends on a diff against the base couples persisted data to base correctness; validations that read raw params for values re-do casting by hand. Every property described below falls out of keeping the two separate.

## The validation base

The runner builds a base struct, then calls your input module's `changeset(base, params, mode)`:

- **Create:** the base is the empty struct (`%ProjectInput{}`). Everything provided casts as a change against nothing.
- **Patch:** the base is `from_subject(ctx.subject)` — the input struct pre-seeded with the record's *current* values, translated into the input vocabulary (public ids rendered, renames applied). This is why the pipeline loads the subject before casting.

With the base in place, ordinary Ecto does the right thing on PATCH with no special handling:

- `validate_required/2` works unmodified: an omitted-but-populated required field passes (the base supplies it through `get_field`), while an explicit nil-clear records a `nil` change and fails.
- Cross-field rules read plain `get_field/2` and see the value the record *will have* — current where omitted, new where provided.

Two boundaries on the seeding:

1. **Scalars only — embeds are never seeded.** They stay at structural defaults (`[]`/`nil`) so that provided arrays cast as pure inserts (replace-wholesale) instead of engaging `cast_embed`'s diff-by-identity machinery.
2. **The base influences validation only, never the write.** As shown next, extraction ignores the changeset's diff entirely — so even a *wrong* `from_subject/1` projection cannot corrupt persisted data. Its blast radius is confined to validation behavior, which is why a mistake there is caught by a CI test (projection completeness) rather than needing runtime defense.

## Extraction

`Enact.updates/2` produces the map that `execute/2` persists:

```elixir
provided = module.fields(ctx.mode) |> Enum.filter(&Enact.provided?(ctx, &1))

changeset
|> Ecto.Changeset.apply_changes()
|> dump_embeds(module)   # embed structs → plain maps, recursively
|> Map.take(provided)
```

Key selection is **presence-in-params intersected with the mode's castable fields** — not the change list. Values come from `apply_changes/1`, with embed structs dumped to plain, atom-keyed maps (schema-driven, so scalar structs like `Date` and `Decimal` pass through intact) — the updates map feeds persistence changesets and JSON encoders directly.

A note on keys: the updates map is **uniformly atom-keyed at every level**, and every atom originates from a schema definition. Client params never mint atoms — `provided?/2` matches string keys by rendering the schema atom *to* a string, and cast drops unknown keys — so the atom space stays closed no matter what the caller sends. (When feeding the map onward, remember Ecto's one rule: don't mix string-keyed entries into it.) This yields a small theorem that carries all the PATCH fidelity:

> For any provided key, either a change exists (you get the casted value), or no change exists *because the provided value equals the base* — in which case `apply_changes` yields that same value anyway. Either way, the updates map contains exactly what the caller said.

The PATCH cases resolve mechanically:

| Caller sends              | Change recorded?         | In updates?          | Effect                    |
| ------------------------- | ------------------------ | -------------------- | ------------------------- |
| key omitted               | no                       | no                   | untouched                 |
| `null` (field populated)  | yes, to `nil`            | yes, as `nil`        | clears                    |
| `null` (field already nil)| no (`nil` == `nil`)      | yes, as `nil`        | no-op, faithful           |
| identical value           | no (value == base)       | yes, same value      | harmless no-op write      |
| `[]` on an embed          | no (both empty)          | yes, as `[]`         | clears the array          |
| new value                 | yes                      | yes, casted value    | updates                   |

Note the third and fourth rows: cast "tosses" the change, and it doesn't matter — the tossed change and the base agreed, so `apply_changes` returns the right value and presence puts the key in the map.

Never use bare `apply_changes/1` output for persistence — the full struct erases omitted-vs-provided, silently turning a PATCH into a PUT.

## Why you'll never need `force_changes:` or `empty_values:`

**`force_changes:`** exists for change-based extraction designs, where a provided-identical value records no change and therefore vanishes from the write. Enact's extraction never reads the change list, so there is nothing to force — the provided-identical row in the table above is handled by presence.

**`empty_values:`** is a live option, just not Enact's decision. The runner never calls `cast/3` — your input module's changeset heads do. Ecto's default treats `""` (and whitespace-only strings) as empty, so `"name": ""` behaves like an explicit nil-clear (present in updates as `nil`, failing `validate_required` on required fields). A strict JSON API that wants `""` and `null` distinguished passes `empty_values: []` in its own `cast` calls, per input module.

### The column convention that keeps this simple

The default cast behavior above is *correct* under one data-layer posture: **optional scalar columns are nullable with no default**, making `NULL` the single representation of empty. Then the whole stack agrees on what "empty" is:

- Empty-ish input (`""`, `"   "`) coalesces to `nil` — the canonical empty — via stock cast; no options, no normalization helpers.
- Explicit `null` is just a clear, which is exactly what Enact's nil-clear semantics express; no null-rejection rules.
- Omission leaves the column at `NULL`; storage `NULL`, `ctx.subject` values, and JSON `null` are all the same value, so serializers translate nothing on the way out either.

The pattern that fights this is the `NOT NULL DEFAULT ''` column (Rails-era discipline that solved the same two-representations problem from the other side, by banning `NULL` instead of `""`). There, `""` is a *legitimate value* that default casting destroys — `""` → `nil` → a NOT NULL violation at persistence. If such a column can't be migrated, treat it as the declared exception: cast those fields with `empty_values: []` plus explicit whitespace normalization, declare them in a module attribute so the policy is greppable, and back it with a host test asserting `""` survives casting (derivable mechanically — any persistence field whose struct default is `""` qualifies; template in the Testing guide, worked example in the Recipes guide). Reserve the pattern for fields where empty-string is genuinely distinct from absent; for everything else, migrate to nullable and delete the machinery.

## Where change-gating still legitimately exists

Two behaviors remain gated on the change list, and both skips are correct:

- `Enact.Validations.unique/3` skips fields with no change — a provided-identical value is already persisted (and would collide with the record itself).
- Resolution skips `nil` reference values — there is nothing to fetch for a clear. (Resolution itself is presence-gated: a reference provided identical to its current value still re-resolves, keeping the `ctx.assigns` contract total and re-authorizing the reference.)

For your own validations, the rule of thumb: read **values** with `get_field/2`; detect **providedness** with `Enact.provided?/2`. Reach for `provided?/2` when a rule must run only because the caller touched a key — including `[]`-clears, which any `get_change`-based gate would miss. It is the sanctioned raw-params read, and the explicit `Enact.` prefix usefully marks the exception.

## Anti-patterns, and what each one breaks

- **Bare `apply_changes/1` for persistence** — erases omitted-vs-provided; every PATCH becomes a full-record write, and base values leak into the database.
- **`get_change(cs, :field) || ctx.subject.field`** — an unlabeled inline projection that is wrong under nil-clears (`get_change` returns `nil` for both "no change" and "changed to nil", so the fallback resurrects the old value exactly when the caller cleared it). The base makes the idiom unnecessary: `get_field/2` already returns result-state.
- **Seeding embeds in `from_subject/1`** — engages `cast_embed`'s diff-by-identity machinery where no diff exists, breaking replace-wholesale array semantics.
- **`default:` on input schema fields** — with presence-based extraction a schema default never persists; it only misleads validations into seeing a value the write will not contain, and it contaminates the patch base for any field `from_subject/1` forgets. `Enact.Guardrails` raises on it; defaults live in the DB column (see the design spec §4.3).
