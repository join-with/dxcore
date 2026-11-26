defmodule DxCore.Core.AgentProtocol do
  @moduledoc """
  The coordinator side of the agent protocol facts that
  `contract/agent-protocol.json` publishes to agents
  (`AgentProtocolContractTest` keeps the two equal).

  A `"shutdown"` push carries `%{"reason" => reason}` with one of
  `shutdown_reasons/0`; an agent stops on any of them. `"no_more_work"` is
  sent only to an idle agent, one the run's `DxCore.Core.Scheduler.LeaveRule`
  released.
  """

  @shutdown_reasons %{
    session_finished: "session_finished",
    coordinator_shutdown: "coordinator_shutdown",
    fair_share: "fair_share",
    no_more_work: "no_more_work"
  }

  @doc "Every reason a coordinator may send with `\"shutdown\"`."
  @spec shutdown_reasons() :: [String.t()]
  def shutdown_reasons, do: Map.values(@shutdown_reasons)

  @doc "The `\"shutdown\"` payload for `reason`; raises on a reason the contract does not list."
  @spec shutdown(:session_finished | :coordinator_shutdown | :fair_share | :no_more_work) ::
          %{String.t() => String.t()}
  def shutdown(reason), do: %{"reason" => Map.fetch!(@shutdown_reasons, reason)}
end
