# Testing Host Applications

Enact's own suite covers the pipeline mechanics. Five test obligations belong to the host application because they depend on your actions, schemas, and tenancy model. This guide provides templates for each. `import Enact.Test` provides `assert_invalid/2`, `build_ctx/1`, and `errors_on/1` throughout.

## The action registry

The templates enumerate your actions, so maintain one explicit list, plus a completeness check so new actions cannot be omitted from the suite:

```elixir
defmodule MyApp.Actions do
  @actions [
    MyApp.Projects.Actions.CreateProject,
    MyApp.Projects.Actions.UpdateProject,
    MyApp.Projects.Actions.ArchiveProject
    # every action, no exceptions
  ]

  def all, do: @actions
end
```

```elixir
test "the registry lists every action module" do
  {:ok, modules} = :application.get_key(:my_app, :modules)

  implemented =
    for mod <- modules,
        {:ok, _} = Code.ensure_loaded(mod),
        behaviours = mod.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten(),
        Enact.Action in behaviours,
        do: mod

  assert Enum.sort(implemented) == Enum.sort(MyApp.Actions.all())
end
```

## 1. Guardrails in CI

The runner checks input schemas lazily on first run. This test moves the check to CI:

```elixir
test "every input schema passes guardrails" do
  for action <- MyApp.Actions.all(), input = action.input(), input != nil do
    mode = Keyword.get(action.config(), :mode, :create)
    Enact.Guardrails.assert_valid_input_schema!(input, mode: mode)
  end
end
```

## 2. Cross-tenant sweep

Run every action as a tenant-A actor against tenant-B's subject and references. Subjects must return `:not_found`. Foreign references must produce only the generic `"not found"` field error; a precise message would reveal that the record exists.

```elixir
describe "cross-tenant isolation" do
  setup do
    %{actor: scope_fixture(org: org_fixture()), other_org: org_fixture()}
  end

  test "tenant-B subjects are not found", %{actor: actor, other_org: other_org} do
    foreign_project = project_fixture(org: other_org)

    params = %{"id" => foreign_project.public_id, "name" => "hijack"}
    assert {:error, %Enact.Error{type: :not_found}} =
             Enact.run(MyApp.Projects.Actions.UpdateProject, params, actor: actor)
  end

  test "tenant-B references produce only the generic message", %{actor: actor, other_org: other_org} do
    foreign_user = user_fixture(org: other_org)

    # enumerate reference fields from the resolvers/0 manifests
    for action <- MyApp.Actions.all(), {_name, {spec, _fetcher}} <- action.resolvers() do
      params = valid_params_for(action, actor) |> put_reference(spec, foreign_user.public_id)
      changeset = assert_invalid(Enact.run(action, params, actor: actor))

      for {_field, messages} <- errors_on(changeset), message <- List.wrap(messages) do
        assert message == "not found",
               "#{inspect(action)} leaked a precise message for a foreign reference: #{message}"
      end
    end
  end
end
```

`valid_params_for/2` and `put_reference/3` are application-specific: a per-action map of known-good params, with the reference field swapped. The scalar spec form is a field atom; the batch form is `[embed_field, item_field]`.

Anonymous variants of the same sweep:

```elixir
test "actions without anonymous?: true reject anonymous actors" do
  for action <- MyApp.Actions.all(),
      not Keyword.get(action.config(), :anonymous?, false) do
    assert {:error, %Enact.Error{type: :forbidden}} =
             Enact.run(action, %{}, actor: :anonymous)
  end
end

test "actor: nil raises everywhere" do
  for action <- MyApp.Actions.all() do
    assert_raise ArgumentError, fn -> Enact.run(action, %{}, actor: nil) end
  end
end
```

## 3. The PATCH matrix (per patch action)

Eight cases per patch action. This example uses an `UpdateProject` action where `name` is required, `priority` is optional, and `milestones` is an embed:

```elixir
describe "UpdateProject PATCH semantics" do
  setup do
    project = project_fixture(name: "Old", priority: 3, milestones: [milestone_fixture()])
    %{actor: scope_for(project), project: project}
  end

  test "omitted keys are untouched", %{actor: actor, project: project} do
    {:ok, updated} = Enact.run(UpdateProject, %{"id" => project.public_id, "priority" => 9}, actor: actor)
    assert updated.name == "Old"
    assert updated.priority == 9
  end

  test "explicit null clears an optional scalar", ctx do
    {:ok, updated} = run_patch(ctx, %{"priority" => nil})
    assert updated.priority == nil
  end

  test "explicit null on a required field is :invalid", ctx do
    assert_invalid(run_patch_raw(ctx, %{"name" => nil}), on: :name)
  end

  test "an omitted required-but-populated field passes validate_required", ctx do
    assert {:ok, _} = run_patch_raw(ctx, %{"priority" => 9})
  end

  test "[] clears the array (and presence-gated validations still run)", ctx do
    {:ok, updated} = run_patch(ctx, %{"milestones" => []})
    assert updated.milestones == []
  end

  test "provided-identical persists as a no-op write", ctx do
    assert {:ok, updated} = run_patch(ctx, %{"name" => "Old"})
    assert updated.name == "Old"
  end

  test "a provided reference re-resolves; an absent one survives", ctx do
    # provided (even identical) → the fetcher runs, re-authorizing the reference
    # absent → untouched, no fetcher call
  end
end
```

## 4. The create matrix

```elixir
test "omitted optionals fall to DB defaults" do
  {:ok, project} = Enact.run(CreateProject, %{"name" => "A", "slug" => "a"}, actor: actor)
  # the column default applies
  assert project.priority == 1
end

test "explicit nil on a required field fails validate_required" do
  assert_invalid(
    Enact.run(CreateProject, %{"name" => nil, "slug" => "a"}, actor: actor),
    on: :name
  )
end
```

## 5. Projection completeness (per patch-mode input module)

If `from_subject/1` omits a field, validations can no longer distinguish nil-clears from omissions for that field. This test fails in CI instead:

```elixir
test "ProjectInput.from_subject/1 is total over scalar fields" do
  # every field populated with a non-nil value
  project = fully_populated_project_fixture()
  base = ProjectInput.from_subject(project)

  embeds = ProjectInput.__schema__(:embeds)

  for field <- ProjectInput.fields(:patch), field not in embeds do
    refute is_nil(Map.get(base, field)),
           "from_subject/1 projects no value for #{inspect(field)}"
  end

  # embeds stay at structural defaults — never seeded
  for embed <- embeds do
    assert Map.get(base, embed) in [[], nil]
  end
end
```

## 6. Resolver coverage

This test catches reference fields added without a resolver. Without one, the raw public-ID string reaches persistence:

```elixir
# legitimately opaque _id fields (external references, idempotency keys) —
# exceptions stay visible instead of weakening the rule
@allowlist %{
  MyApp.Payments.Actions.RecordExternalCharge => [:provider_charge_id]
}

test "every *_id input field has a resolver" do
  for action <- MyApp.Actions.all(), input = action.input(), input != nil do
    mode = Keyword.get(action.config(), :mode, :create)
    allowed = Map.get(@allowlist, action, [])

    covered =
      Enum.flat_map(action.resolvers(), fn
        {_name, {field, _fetcher}} when is_atom(field) -> [field]
        {_name, {[_embed, item_field], _fetcher}} -> [item_field]
      end)

    for field <- input.fields(mode),
        String.ends_with?(Atom.to_string(field), "_id"),
        field not in allowed do
      assert field in covered,
             "#{inspect(action)}: #{inspect(field)} has no resolver and is not allowlisted"
    end
  end
end
```

## 7. Doc-schema reconciliation (if you document your API)

Enact has no knowledge of OpenApiSpex. Drift prevention is a host-side comparison of the `fields/1` manifests against your documentation source of truth:

```elixir
test "ProjectInput matches the documented request schema" do
  documented = MyAppWeb.Schemas.ProjectCreateRequest.schema().properties |> Map.keys() |> Enum.sort()
  actual = ProjectInput.fields(:create) |> Enum.sort()

  assert documented == actual,
         "API docs and input schema have drifted — change both deliberately"
end
```

## 8. Empty-string-at-rest drift

Any persistence field whose struct default is `""` is an empty-string-at-rest column (`NOT NULL DEFAULT ''`). Its input cast must preserve `""` instead of coalescing it to `nil` (see recipe 5 in the Recipes guide). This test derives those fields mechanically and fails when one is wired with a plain cast:

```elixir
# {input module, persistence schema, mode} for every input casting such fields
@empty_string_pairs [
  {CustomerInput, Customer, :create},
  {CustomerInput, Customer, :patch}
]

defp empty_string_fields(schema) do
  for field <- schema.__schema__(:fields),
      Map.get(struct(schema), field) == "",
      do: field
end

test "empty-string-at-rest fields survive input casting" do
  for {input, persistence, mode} <- @empty_string_pairs,
      field <- empty_string_fields(persistence),
      field in input.fields(mode) do
    changeset = input.changeset(struct(input), %{Atom.to_string(field) => ""}, mode)

    assert Ecto.Changeset.get_field(changeset, field) == "",
           "#{inspect(input)} coalesced \"\" to nil for #{inspect(field)} — " <>
             "cast it with empty_values: [] (see the Change Detection guide)"
  end
end
```

## Dry-run additions

For any action exposed through a confirmation flow: assert that `dry_run` performs no writes, that `preview.updates` equals what an identical `run` persists, and that a mismatched or cross-action `confirm_digest` returns `:conflict`.
