defmodule DxCore.Agents.Web.DispatcherChannel do
  use DxCore.Agents.Web, :channel

  alias DxCore.Agents.Sessions

  @impl true
  def join("dispatcher:" <> session_id, _params, socket) do
    {:ok, assign(socket, :session_id, session_id)}
  end

  @impl true
  def handle_in("submit_graph", payload, socket) do
    %{"run_id" => run_id, "tasks" => raw_tasks} = payload
    session_id = socket.assigns.session_id
    scope = socket.assigns.current_scope
    failure_strategy = resolve_failure_strategy(payload)

    json = Jason.encode!(%{"tasks" => raw_tasks})
    {:ok, graph} = DxCore.Core.TaskGraph.parse(json)

    # Register run with Sessions (validates tenant ownership and session existence)
    case Sessions.register_run(scope, session_id, run_id) do
      :ok ->
        submit_graph(socket, session_id, run_id, graph, failure_strategy)

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  @endpoint DxCore.Agents.Web.Endpoint

  @impl true
  def handle_in("cancel_run", %{"run_id" => run_id}, socket) do
    session_id = socket.assigns.session_id

    case DxCore.Core.Scheduler.whereis(session_id, run_id) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(DxCore.Core.SchedulerSupervisor, pid)

        @endpoint.broadcast!("dispatcher:#{session_id}", "run_complete", %{
          "run_id" => run_id,
          "status" => "cancelled",
          "summary" => nil
        })
    end

    {:noreply, socket}
  end

  defp resolve_failure_strategy(payload) do
    case payload["failure_strategy"] do
      strategy when strategy in ["fail_fast", "continue_all"] ->
        String.to_existing_atom(strategy)

      _ ->
        Application.get_env(:dxcore_coordinator_oss, :default_failure_strategy, :continue_all)
    end
  end

  defp submit_graph(socket, session_id, run_id, graph, failure_strategy) do
    # Stop existing scheduler if any
    case DxCore.Core.Scheduler.whereis(session_id, run_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(DxCore.Core.SchedulerSupervisor, pid)
    end

    plugin =
      Application.get_env(
        :dxcore_coordinator_oss,
        :scheduler_plugin,
        DxCore.Core.Scheduler.NullPlugin
      )

    # Start scheduler under DynamicSupervisor
    {:ok, _pid} =
      DynamicSupervisor.start_child(
        DxCore.Core.SchedulerSupervisor,
        {DxCore.Core.Scheduler,
         graph: graph,
         run_id: run_id,
         session_id: session_id,
         plugin: plugin,
         failure_strategy: failure_strategy}
      )

    total_tasks = map_size(graph.tasks)
    cached_tasks = Enum.count(graph.tasks, fn {_, t} -> t.cache_status == :hit end)

    # Notify agents in this session to check for tasks
    DxCore.Agents.Web.Endpoint.broadcast!("agent:#{session_id}", "tasks_available", %{})

    {:reply,
     {:ok,
      %{
        "run_id" => run_id,
        "total_tasks" => total_tasks,
        "cached_tasks" => cached_tasks
      }}, socket}
  end
end
