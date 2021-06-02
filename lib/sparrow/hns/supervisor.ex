defmodule Sparrow.HNS.V1.Supervisor do
  @moduledoc """
  Main HNS supervisor.
  Supervises HNS token bearer and pool supervisor.
  """
  use Supervisor

  @spec start_link([Keyword.t()]) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg)
  end

  @spec init([Keyword.t()]) ::
          {:ok, {:supervisor.sup_flags(), [:supervisor.child_spec()]}}
  def init(raw_hns_config) do
    children = [
      %{
        id: Sparrow.HNS.V1.TokenBearer,
        start: {Sparrow.HNS.V1.TokenBearer, :start_link, [raw_hns_config]}
      },
      Sparrow.HNS.V1.ProjectIdBearer,
      {Sparrow.HNS.V1.Pool.Supervisor, raw_hns_config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
