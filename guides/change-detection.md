# Change Detection

This guide explains how Enact determines what a write contains, and why common Ecto PATCH workarounds (`force_changes:`, subject-fallback reads, manual merge logic) are not needed.

## The two questions

Every write answers two separate questions, each with its own mechanism:

- **What did the caller provide?** Answered by key presence in the raw params, through `Enact.provided?/2` and `Enact.updates/2`. This determines what is persisted.
- **What is the current state?** Answered by the validation base — the struct the changeset is cast over. This determines what validations see. It never affects what is persisted.

The two mechanisms stay separate. If extraction depended on a diff against the base, persisted data would depend on base correctness. If validations read raw params for values, they would repeat casting by hand.

## The validation base

The runner builds a base struct and calls the input module's `changeset(base, params, mode)`:

- **Create:** the base is the empty struct (`%ProjectInput{}`). Every provided field casts as a change.
- **Patch:** the base is `from_subject(ctx.subject)` — the input struct populated with the record's current values, translated into the input representation (public IDs rendered, fields renamed). This is why the pipeline loads the subject before casting.

With the base in place, standard Ecto functions behave correctly on PATCH:

- `validate_required/2` works without modification. A required field that is omitted but populated on the record passes, because the base supplies the value through `get_field`. An explicit nil-clear records a `nil` change and fails.
- Cross-field rules read `get_field/2` and see the value the record will have after the write: the current value where omitted, the new value where provided.

Two rules constrain the base:

1. **Only scalar fields are seeded.** Embeds stay at their structural defaults (`[]` or `nil`), so provided arrays cast as inserts rather than engaging `cast_embed`'s diff-by-identity behavior.
2. **The base affects validation only.** Extraction ignores the changeset diff, so an incorrect `from_subject/1` projection cannot corrupt persisted data. Projection mistakes affect validation behavior only, and the projection-completeness test (see the Testing guide) catches them in CI.

## Extraction

`Enact.updates/2` produces the map that `execute/2` persists:

```elixir
provided = module.fields(ctx.mode) |> Enum.filter(&Enact.provided?(ctx, &1))

changeset
|> Ecto.Changeset.apply_changes()
|> dump_embeds(module)   # embed structs → plain maps, recursively
|> Map.take(provided)
```

Key selection is presence-in-params intersected with the mode's castable fields (`fields/1`). Extraction does not read the change list. Values come from `apply_changes/1`, with embed structs dumped to plain, atom-keyed maps. The dump is schema-driven, so scalar structs such as `Date` and `Decimal` pass through unchanged. The resulting map can be passed directly to persistence changesets and JSON encoders.

The updates map is atom-keyed at every level, and every atom comes from a schema definition. Client params never create atoms: `provided?/2` matches string keys by converting the schema atom to a string, and `cast` drops unknown keys. When passing the map to Ecto functions, do not merge string-keyed entries into it — Ecto rejects mixed-key maps.

For any provided key, one of two cases holds: a change exists, and `apply_changes` yields the casted value; or no change exists because the provided value equals the base value, and `apply_changes` yields that same value. In both cases the updates map contains what the caller provided.

Embeds declared in the input module's `partial_embeds/1` manifest extend presence one level down: their dumped maps contain only the sub-keys the caller provided, with the same omitted-vs-null fidelity as top-level fields. See recipe 6 in the Recipes guide for the merge pattern.

"Equals" here is Ecto's semantic equality (`Ecto.Type.equal?`), not structural equality. For types with multiple representations of one value — `Decimal` `1.0` versus `1.00` — a provided value semantically equal to the base records no change, and updates carry the base's representation. The persisted value is semantically what the caller sent; only its formatting can differ, and it is consistent between a dry run and the confirming run.

The PATCH cases resolve as follows:

| Caller sends              | Change recorded?         | In updates?          | Effect                    |
| ------------------------- | ------------------------ | -------------------- | ------------------------- |
| key omitted               | no                       | no                   | untouched                 |
| `null` (field populated)  | yes, to `nil`            | yes, as `nil`        | clears                    |
| `null` (field already nil)| no (`nil` == `nil`)      | yes, as `nil`        | no-op write               |
| identical value           | no (value == base)       | yes, same value      | no-op write               |
| `[]` on an embed          | no (both empty)          | yes, as `[]`         | clears the array          |
| new value                 | yes                      | yes, casted value    | updates                   |

In the third and fourth rows, cast records no change. This does not affect the result: the base value equals the provided value, so `apply_changes` returns it and presence includes the key.

Do not use bare `apply_changes/1` output for persistence. The full struct does not distinguish omitted from provided fields, which turns a PATCH into a full-record write.

## `force_changes:` and `empty_values:`

**`force_changes:`** exists for designs that extract from the change list, where a value provided identical to the current one records no change and is dropped from the write. Enact's extraction does not read the change list, so this option is not needed.

**`empty_values:`** remains available, but it is a host decision. The runner never calls `cast/3`; the input module's changeset heads do. Ecto's default treats `""` and whitespace-only strings as empty on every field type, so `"name": ""` behaves like an explicit nil-clear — and `"count": ""` on an integer field silently becomes a null-clear instead of a type error.

`Enact.InputSchema.cast_input/4` packages the recommended JSON API policy so this does not have to be configured per cast call. It derives empty-string handling from each field's type: `""` on a non-string field is a cast error (`"is invalid"`); empty-ish `:string` values (`""`, whitespace-only) coalesce to `nil`, while non-empty values pass through as sent — casting interprets input, it never modifies values. One option declares the exception: `keep_empty_strings:` for fields where `""` is a value. `Enact.Test.assert_rejects_empty_strings/3` verifies the non-string outcome in CI regardless of which casting mechanism a module uses.

### Column convention

The default cast behavior is correct when optional scalar columns are nullable with no default, making `NULL` the single representation of an empty value:

- Empty input (`""`, `"   "`) coalesces to `nil` through the default cast, with no options or normalization helpers.
- Explicit `null` is a clear, which is what Enact's nil-clear semantics express. No null-rejection rules are needed.
- Omission leaves the column `NULL`. Storage `NULL`, `ctx.subject` values, and JSON `null` are the same value, so serializers do not translate on reads.

`NOT NULL DEFAULT ''` columns conflict with this behavior. On such columns `""` is a valid value, but the default cast converts it to `nil`, which then violates the NOT NULL constraint at persistence. If you cannot migrate the column to nullable, declare the exception: list those fields in `cast_input/4`'s `keep_empty_strings:` option, and add a host test asserting that `""` survives casting. The qualifying fields are mechanically derivable — any persistence field whose struct default is `""`. See the Testing guide for the test template and the Recipes guide for a worked example. Use this pattern only for fields where the empty string is meaningful as distinct from absent.

## Where change-gating exists

Two behaviors read the change list, and both skips are correct:

- `Enact.Validations.unique/3` skips fields with no change. A value identical to the current one is already persisted and would match the record itself. When the field *is* changing, pass `except: ctx.subject` so the current row is not treated as a collision.
- Resolution skips `nil` reference values, since a clear resolves nothing. Resolution itself is presence-gated: a reference provided with a value identical to the current one still resolves, so a non-nil reference in updates always has a corresponding entry in `ctx.assigns`.

In your own validations, read values with `get_field/2` and detect providedness with `Enact.provided?/2`. Use `provided?/2` for rules that run only when the caller included a key, including `[]`-clears, which a `get_change`-based check would miss.

## Anti-patterns

- **Bare `apply_changes/1` for persistence.** Does not distinguish omitted from provided fields; every PATCH becomes a full-record write and base values are written to the database.
- **`get_change(cs, :field) || ctx.subject.field`.** Incorrect under nil-clears: `get_change` returns `nil` both when there is no change and when the change is `nil`, so the fallback restores the old value when the caller cleared the field. Use `get_field/2` instead; the base makes it return the correct result-state.
- **Seeding embeds in `from_subject/1`.** Engages `cast_embed`'s diff-by-identity behavior and breaks replace-wholesale array semantics.
- **`default:` on input schema fields.** With presence-based extraction, a schema default never persists. It causes validations to see a value the write does not contain, and it fills any field `from_subject/1` misses in the patch base. `Enact.Guardrails` raises on it. Declare defaults on the database column instead (see the design spec, section 4.3).
