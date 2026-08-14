defmodule EnactTest.Project do
  @moduledoc "A fixture domain record (the persistence-side struct)."
  defstruct [:id, :name, :slug, :priority, :owner_id, milestones: []]
end

defmodule EnactTest.MilestoneInput do
  @moduledoc """
  A fixture nested item schema — `changeset/2`, invoked by `cast_embed`,
  exempt from the `Enact.InputSchema` contract (§4.1 asymmetry).
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Enact.InputSchema, only: [cast_input: 3]

  @primary_key false
  embedded_schema do
    field :title, :string
    field :due_on, :date
    field :owner_id, :string
  end

  def changeset(item, params) do
    item
    |> cast_input(params, [:title, :due_on, :owner_id])
    |> validate_required([:title])
  end
end

defmodule EnactTest.ProjectInput do
  @moduledoc "A fixture top-level input schema shared by create and patch."
  use Ecto.Schema
  use Enact.InputSchema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :name, :string
    field :slug, :string
    field :priority, :integer
    field :owner_id, :string
    embeds_many :milestones, EnactTest.MilestoneInput
  end

  @scalars ~w(name slug priority owner_id)a
  # slug immutable after create
  @patch_scalars @scalars -- [:slug]
  @required ~w(name slug)a

  @impl Enact.InputSchema
  def changeset(base, params, :create) do
    base
    |> cast_input(params, @scalars)
    |> validate_required(@required)
    |> cast_embed(:milestones)
    |> base_validations()
  end

  def changeset(base, params, :patch) do
    base
    |> cast_input(params, @patch_scalars)
    |> validate_required(@required)
    |> cast_embed(:milestones)
    |> base_validations()
  end

  @impl Enact.InputSchema
  def fields(:create), do: @scalars ++ [:milestones]
  def fields(:patch), do: @patch_scalars ++ [:milestones]

  @impl Enact.InputSchema
  def from_subject(%EnactTest.Project{} = project) do
    %__MODULE__{
      name: project.name,
      slug: project.slug,
      priority: project.priority,
      owner_id: project.owner_id
    }
  end

  defp base_validations(changeset) do
    validate_number(changeset, :priority, greater_than: 0)
  end
end

defmodule EnactTest.CreateProject do
  @moduledoc "A minimal create-mode fixture action."
  use Enact.Action

  @impl Enact.Action
  def input, do: EnactTest.ProjectInput

  @impl Enact.Action
  def execute(changeset, ctx), do: {:ok, Enact.updates(changeset, ctx)}
end

defmodule EnactTest.UpdateProject do
  @moduledoc """
  A minimal patch-mode fixture action. The subject comes from the process
  dictionary (`Process.put(:enact_subject, project)`) — tests run in the
  same process as the pipeline.
  """
  use Enact.Action

  @impl Enact.Action
  def config, do: [mode: :patch]

  @impl Enact.Action
  def input, do: EnactTest.ProjectInput

  @impl Enact.Action
  def load_subject(_params, _ctx), do: Process.get(:enact_subject)

  @impl Enact.Action
  def execute(changeset, ctx), do: {:ok, Enact.updates(changeset, ctx)}
end
