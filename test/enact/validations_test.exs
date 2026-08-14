defmodule Enact.ValidationsTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset
  import Enact.Validations

  alias EnactTest.FakeRepo

  defmodule ProjectRecord do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: false}
    schema "projects" do
      field :slug, :string
      field :org_id, :integer
    end
  end

  defp changeset(params) do
    cast({%{}, %{slug: :string, org_id: :integer}}, params, [:slug, :org_id])
  end

  describe "check/2" do
    test "no-ops when the changeset is already invalid" do
      invalid = changeset(%{}) |> add_error(:slug, "bad")

      assert check(invalid, fn _ -> raise "must not run" end) == invalid
    end

    test "applies the function when valid" do
      valid = changeset(%{"slug" => "x"})

      assert check(valid, &put_change(&1, :org_id, 7)).changes.org_id == 7
    end
  end

  describe "unique/3" do
    test "skips when the field has no change" do
      result = unique(changeset(%{}), :slug, query: ProjectRecord, repo: FakeRepo)

      assert result.valid?
      refute_received {FakeRepo, :exists?, _}
    end

    test "passes through when no matching row exists" do
      Process.put(:fake_repo_exists?, false)

      result = unique(changeset(%{"slug" => "x"}), :slug, query: ProjectRecord, repo: FakeRepo)

      assert result.valid?
      assert_received {FakeRepo, :exists?, query}
      assert inspect(query) =~ "slug"
    end

    test "adds a :unique-tagged error when a row exists" do
      Process.put(:fake_repo_exists?, true)

      result = unique(changeset(%{"slug" => "x"}), :slug, query: ProjectRecord, repo: FakeRepo)

      refute result.valid?
      assert {"has already been taken", meta} = result.errors[:slug]
      assert meta[:validation] == :unique
    end

    test "scope conditions are included in the query" do
      Process.put(:fake_repo_exists?, false)

      unique(changeset(%{"slug" => "x"}), :slug,
        query: ProjectRecord,
        repo: FakeRepo,
        scope: [org_id: 9]
      )

      assert_received {FakeRepo, :exists?, query}
      assert inspect(query) =~ "org_id"
    end

    test "except: a struct excludes it by primary key" do
      Process.put(:fake_repo_exists?, false)
      current = %ProjectRecord{id: 7, slug: "x"}

      unique(changeset(%{"slug" => "x"}), :slug,
        query: ProjectRecord,
        repo: FakeRepo,
        except: current
      )

      assert_received {FakeRepo, :exists?, query}
      inspected = inspect(query)
      assert inspected =~ "id"
      assert inspected =~ "7"
    end

    test "except: an id excludes that id column" do
      Process.put(:fake_repo_exists?, false)

      unique(changeset(%{"slug" => "x"}), :slug,
        query: ProjectRecord,
        repo: FakeRepo,
        except: 7
      )

      assert_received {FakeRepo, :exists?, query}
      inspected = inspect(query)
      assert inspected =~ "id"
      assert inspected =~ "7"
    end

    test "except: a keyword excludes those columns" do
      Process.put(:fake_repo_exists?, false)

      unique(changeset(%{"slug" => "x"}), :slug,
        query: ProjectRecord,
        repo: FakeRepo,
        except: [id: 7]
      )

      assert_received {FakeRepo, :exists?, query}
      inspected = inspect(query)
      assert inspected =~ "id"
      assert inspected =~ "7"
    end

    test "except: raises on a nil primary key" do
      assert_raise ArgumentError, ~r/except: :id is nil/, fn ->
        unique(changeset(%{"slug" => "x"}), :slug,
          query: ProjectRecord,
          repo: FakeRepo,
          except: %ProjectRecord{slug: "x"}
        )
      end
    end

    test "except: raises on an unknown value" do
      assert_raise ArgumentError, ~r/expected a struct, id, or keyword/, fn ->
        unique(changeset(%{"slug" => "x"}), :slug,
          query: ProjectRecord,
          repo: FakeRepo,
          except: :nope
        )
      end
    end

    test "composes with check/2 so garbage input never queries" do
      invalid = changeset(%{"slug" => "x"}) |> add_error(:org_id, "bad")

      check(invalid, &unique(&1, :slug, query: ProjectRecord, repo: FakeRepo))

      refute_received {FakeRepo, :exists?, _}
    end
  end
end
