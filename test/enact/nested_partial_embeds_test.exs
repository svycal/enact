defmodule Enact.NestedPartialEmbedsTest do
  use ExUnit.Case, async: true

  alias Enact.Context

  defmodule OptInInput do
    use Ecto.Schema
    use Enact.EmbeddedInputSchema, partial: true

    @primary_key false
    embedded_schema do
      field :visible, :boolean
      field :label, :string
    end

    def changeset(item, params), do: cast_input(item, params, [:visible, :label])
  end

  # not partial: replaced wholesale wherever it is embedded
  defmodule LocationInput do
    use Ecto.Schema
    use Enact.EmbeddedInputSchema

    @primary_key false
    embedded_schema do
      field :kind, :string
      field :address, :string
      embeds_one :opt_in, OptInInput
    end

    def changeset(item, params) do
      item
      |> cast_input(params, [:kind, :address])
      |> Ecto.Changeset.cast_embed(:opt_in)
    end
  end

  defmodule FormInput do
    use Ecto.Schema
    use Enact.EmbeddedInputSchema, partial: true

    @primary_key false
    embedded_schema do
      field :title, :string
      embeds_one :opt_in, OptInInput
      embeds_one :location, LocationInput
      embeds_many :extras, OptInInput
    end

    def changeset(item, params) do
      item
      |> cast_input(params, [:title])
      |> Ecto.Changeset.cast_embed(:opt_in)
      |> Ecto.Changeset.cast_embed(:location)
      |> Ecto.Changeset.cast_embed(:extras)
    end
  end

  defmodule LinkInput do
    use Ecto.Schema
    use Enact.InputSchema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :name, :string
      embeds_one :form, FormInput
    end

    @impl Enact.InputSchema
    def changeset(base, params, _mode) do
      base
      |> cast_input(params, [:name])
      |> cast_embed(:form)
    end

    @impl Enact.InputSchema
    def fields(_mode), do: [:name, :form]

    @impl Enact.InputSchema
    def from_subject(link), do: %__MODULE__{name: link.name}
  end

  @subject %{
    name: "Link",
    form: %{
      title: "Stored title",
      opt_in: %{visible: true, label: "Stored label"},
      location: %{kind: "phone", address: "555", opt_in: %{visible: true, label: "Loc"}},
      extras: [%{visible: true, label: "Extra"}]
    }
  }

  defp build(params, subject \\ @subject) do
    ctx = %Context{params: params, mode: :patch, subject: subject}
    changeset = LinkInput.changeset(LinkInput.from_subject(subject), params, :patch)
    assert changeset.valid?
    {changeset, ctx}
  end

  defp updates(params) do
    {changeset, ctx} = build(params)
    Enact.updates(changeset, ctx)
  end

  defp merged(params, subject \\ @subject) do
    {changeset, ctx} = build(params, subject)
    Enact.merged(changeset, ctx, :form)
  end

  describe "updates/2 with a partial embed inside a partial embed" do
    test "carries only the provided sub-keys at the second level" do
      assert updates(%{"form" => %{"opt_in" => %{"visible" => false}}}) ==
               %{form: %{opt_in: %{visible: false}}}
    end

    test "an explicitly-null nested sub-key is present as nil" do
      assert updates(%{"form" => %{"opt_in" => %{"label" => nil}}}) ==
               %{form: %{opt_in: %{label: nil}}}
    end

    test "an explicitly-null nested object is present as nil" do
      assert updates(%{"form" => %{"opt_in" => nil}}) == %{form: %{opt_in: nil}}
    end

    test "an empty nested object is absent, and so is its otherwise-empty parent" do
      assert updates(%{"form" => %{"opt_in" => %{}}}) == %{}
    end

    test "an empty nested object is absent next to a provided sibling" do
      assert updates(%{"form" => %{"title" => "New", "opt_in" => %{}}}) ==
               %{form: %{title: "New"}}
    end

    test "a nested object with only undeclared keys is absent" do
      assert updates(%{"name" => "N", "form" => %{"opt_in" => %{"nope" => 1}}}) ==
               %{name: "N"}
    end
  end

  describe "updates/2 with a partial embed inside a replace-wholesale embed" do
    test "the wholesale embed keeps every key" do
      assert updates(%{"form" => %{"location" => %{"kind" => "zoom"}}}) ==
               %{form: %{location: %{kind: "zoom", address: nil, opt_in: nil}}}
    end

    test "the partial embed carries only the provided sub-keys" do
      params = %{"form" => %{"location" => %{"opt_in" => %{"visible" => false}}}}

      assert updates(params) ==
               %{form: %{location: %{kind: nil, address: nil, opt_in: %{visible: false}}}}
    end

    test "an empty partial embed is present as an empty map" do
      params = %{"form" => %{"location" => %{"kind" => "zoom", "opt_in" => %{}}}}

      assert updates(params) ==
               %{form: %{location: %{kind: "zoom", address: nil, opt_in: %{}}}}
    end
  end

  describe "updates/2 inside an embeds_many" do
    test "a partial module is replaced wholesale" do
      assert updates(%{"form" => %{"extras" => [%{"visible" => false}]}}) ==
               %{form: %{extras: [%{visible: false, label: nil}]}}
    end
  end

  describe "merged/4 with a partial embed inside a partial embed" do
    test "merges the nested object key by key" do
      assert merged(%{"form" => %{"opt_in" => %{"visible" => false}}}) == %{
               title: "Stored title",
               opt_in: %{visible: false, label: "Stored label"},
               location: @subject.form.location,
               extras: @subject.form.extras
             }
    end

    test "an explicitly-null nested sub-key reads as nil" do
      assert merged(%{"form" => %{"opt_in" => %{"label" => nil}}}).opt_in ==
               %{visible: true, label: nil}
    end

    test "an explicitly-null nested object reads as nil" do
      assert merged(%{"form" => %{"opt_in" => nil}}).opt_in == nil
    end

    test "an omitted nested object reads the current value" do
      assert merged(%{"form" => %{"title" => "New"}}) == %{@subject.form | title: "New"}
    end

    test "an empty nested object reads the current value" do
      assert merged(%{"form" => %{"opt_in" => %{}}}).opt_in == @subject.form.opt_in
    end

    test "with no current nested object, unprovided nested keys read nil" do
      subject = put_in(@subject, [:form, :opt_in], nil)

      assert merged(%{"form" => %{"opt_in" => %{"visible" => false}}}, subject).opt_in ==
               %{visible: false, label: nil}
    end

    test "with no current object at all, unprovided keys read nil" do
      subject = %{@subject | form: nil}

      assert merged(%{"form" => %{"opt_in" => %{"visible" => false}}}, subject) == %{
               title: nil,
               opt_in: %{visible: false, label: nil},
               location: nil,
               extras: nil
             }
    end
  end

  describe "merged/4 with a subject that stores structs" do
    defmodule StoredOptIn do
      defstruct [:id, :visible, :label, :internal]
    end

    defmodule StoredForm do
      defstruct [:id, :title, :opt_in, :location, extras: []]
    end

    defp stored do
      %{
        name: "Link",
        form: %StoredForm{
          id: "form",
          title: "Stored title",
          opt_in: %StoredOptIn{id: "opt", visible: true, label: "Stored label", internal: "x"},
          location: nil,
          extras: [%StoredOptIn{id: "extra", visible: true, label: "Extra", internal: "y"}]
        }
      }
    end

    @plain %{
      title: "Stored title",
      opt_in: %{visible: true, label: "Stored label"},
      location: nil,
      extras: [%{visible: true, label: "Extra"}]
    }

    test "an unprovided nested embed reads as plain maps with the item schema's fields" do
      assert merged(%{"form" => %{"title" => "New"}}, stored()) == %{@plain | title: "New"}
    end

    test "an omitted embed reads as plain maps" do
      assert merged(%{"name" => "New"}, stored()) == @plain
    end

    test "an empty nested object and an omitted one read the same" do
      assert merged(%{"form" => %{"opt_in" => %{}}}, stored()) ==
               merged(%{"form" => %{}}, stored())
    end
  end

  describe "merged/4 with a partial embed inside a replace-wholesale embed" do
    test "the wholesale embed reads every key from the incoming value" do
      assert merged(%{"form" => %{"location" => %{"kind" => "zoom"}}}).location ==
               %{kind: "zoom", address: nil, opt_in: nil}
    end

    test "the partial embed merges over the stored value" do
      params = %{"form" => %{"location" => %{"opt_in" => %{"visible" => false}}}}

      assert merged(params).location ==
               %{kind: nil, address: nil, opt_in: %{visible: false, label: "Loc"}}
    end

    test "an empty partial embed reads the stored value" do
      params = %{"form" => %{"location" => %{"kind" => "zoom", "opt_in" => %{}}}}

      assert merged(params).location ==
               %{kind: "zoom", address: nil, opt_in: %{visible: true, label: "Loc"}}
    end
  end

  describe "merged/4 on an embed whose module is not partial" do
    defmodule VenueInput do
      use Ecto.Schema
      use Enact.InputSchema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        embeds_one :location, LocationInput
      end

      @impl Enact.InputSchema
      def changeset(base, params, _mode), do: base |> cast(params, []) |> cast_embed(:location)

      @impl Enact.InputSchema
      def fields(_mode), do: [:location]

      @impl Enact.InputSchema
      def from_subject(_venue), do: %__MODULE__{}
    end

    @venue %{location: @subject.form.location}

    defp venue_merged(params) do
      ctx = %Context{params: params, mode: :patch, subject: @venue}
      changeset = VenueInput.changeset(%VenueInput{}, params, :patch)
      Enact.merged(changeset, ctx, :location)
    end

    test "a provided embed replaces scalars and merges its partial embed" do
      params = %{"location" => %{"kind" => "zoom", "opt_in" => %{"label" => "New"}}}

      assert venue_merged(params) ==
               %{kind: "zoom", address: nil, opt_in: %{visible: true, label: "New"}}
    end

    test "an omitted embed reads the current value" do
      assert venue_merged(%{}) == @venue.location
    end

    test "an explicitly-null embed reads every key as nil" do
      assert venue_merged(%{"location" => nil}) == %{kind: nil, address: nil, opt_in: nil}
    end
  end

  describe "merged/4 with embeds_many and explicit keys" do
    test "a provided embeds_many replaces the current value" do
      assert merged(%{"form" => %{"extras" => [%{"visible" => false}]}}).extras ==
               [%{visible: false, label: nil}]
    end

    test "an explicit key list restricts the result" do
      {changeset, ctx} = build(%{"form" => %{"title" => "New"}})
      assert Enact.merged(changeset, ctx, :form, [:title]) == %{title: "New"}
    end
  end

  describe "three partial levels" do
    defmodule ThemeInput do
      use Ecto.Schema
      use Enact.EmbeddedInputSchema, partial: true

      @primary_key false
      embedded_schema do
        field :color, :string
        field :font, :string
      end

      def changeset(item, params), do: cast_input(item, params, [:color, :font])
    end

    defmodule PageInput do
      use Ecto.Schema
      use Enact.EmbeddedInputSchema, partial: true

      @primary_key false
      embedded_schema do
        field :heading, :string
        embeds_one :theme, ThemeInput
      end

      def changeset(item, params) do
        item |> cast_input(params, [:heading]) |> Ecto.Changeset.cast_embed(:theme)
      end
    end

    defmodule SiteInput do
      use Ecto.Schema
      use Enact.EmbeddedInputSchema, partial: true

      @primary_key false
      embedded_schema do
        field :domain, :string
        embeds_one :page, PageInput
      end

      def changeset(item, params) do
        item |> cast_input(params, [:domain]) |> Ecto.Changeset.cast_embed(:page)
      end
    end

    defmodule AccountInput do
      use Ecto.Schema
      use Enact.InputSchema
      import Ecto.Changeset

      @primary_key false
      embedded_schema do
        embeds_one :site, SiteInput
      end

      @impl Enact.InputSchema
      def changeset(base, params, _mode), do: base |> cast(params, []) |> cast_embed(:site)

      @impl Enact.InputSchema
      def fields(_mode), do: [:site]

      @impl Enact.InputSchema
      def from_subject(_account), do: %__MODULE__{}
    end

    @account %{
      site: %{
        domain: "example.com",
        page: %{heading: "Welcome", theme: %{color: "red", font: "serif"}}
      }
    }

    defp account(params) do
      ctx = %Context{params: params, mode: :patch, subject: @account}
      {AccountInput.changeset(%AccountInput{}, params, :patch), ctx}
    end

    test "updates carry only the sub-key provided at the third level" do
      {changeset, ctx} = account(%{"site" => %{"page" => %{"theme" => %{"color" => "blue"}}}})

      assert Enact.updates(changeset, ctx) ==
               %{site: %{page: %{theme: %{color: "blue"}}}}
    end

    test "merged keeps the stored values at every level" do
      {changeset, ctx} = account(%{"site" => %{"page" => %{"theme" => %{"color" => "blue"}}}})

      assert Enact.merged(changeset, ctx, :site) == %{
               domain: "example.com",
               page: %{heading: "Welcome", theme: %{color: "blue", font: "serif"}}
             }
    end

    test "an empty object at the third level leaves no updates" do
      {changeset, ctx} = account(%{"site" => %{"page" => %{"theme" => %{}}}})

      assert Enact.updates(changeset, ctx) == %{}
      assert Enact.merged(changeset, ctx, :site) == @account.site
    end
  end
end
