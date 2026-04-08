defmodule DxCore.Core.TaskLogBuffer do
  @moduledoc "ETS-based buffer for task log lines, used to build run summaries."
  use GenServer

  def start_link(opts) do
    table_name = Keyword.fetch!(opts, :table_name)
    GenServer.start_link(__MODULE__, table_name, name: Keyword.get(opts, :name, __MODULE__))
  end

  def buffer(table, session_id, task_id, line) do
    :ets.insert(table, {{session_id, task_id}, line, System.monotonic_time()})
  end

  def get_output(table, session_id, task_id) do
    table
    |> :ets.match_object({{session_id, task_id}, :"$1", :"$2"})
    |> Enum.sort_by(fn {_key, _line, ts} -> ts end)
    |> Enum.map(fn {_key, line, _ts} -> line end)
    |> Enum.join("\n")
  end

  def cleanup(table, session_id) do
    :ets.match_delete(table, {{session_id, :_}, :_, :_})
  end

  @impl true
  def init(table_name) do
    table = :ets.new(table_name, [:named_table, :public, :duplicate_bag])
    {:ok, table}
  end
end
