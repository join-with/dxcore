defmodule DxCore.Agents.TaskGraph do
  @moduledoc "Thin delegate to DxCore.Core.TaskGraph."

  defdelegate parse(json_string), to: DxCore.Core.TaskGraph
  defdelegate initial_frontier(graph), to: DxCore.Core.TaskGraph
end
