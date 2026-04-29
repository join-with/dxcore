defmodule DxCore.Agents.Web.DispatcherChannel do
  use DxCore.Agents.Web, :channel

  alias DxCore.Agents.Sessions

  @impl true
  def join("dispatcher:" <> session_id, _params, socket) do
    {:ok,
     assign(socket,
       session_id: session_id,
       dispatcher_topic: "dispatcher:#{session_id}",
       agent_topic: "agent:#{session_id}"
     )}
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

    case DxCore.Core.Scheduler.whereis(nil, session_id, run_id) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(DxCore.Core.SchedulerSupervisor, pid)

        @endpoint.broadcast!(socket.assigns.dispatcher_topic, "run_complete", %{
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
    case DxCore.Core.Scheduler.whereis(nil, session_id, run_id) do
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
    {:ok, scheduler_pid} =
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

    if total_tasks == 0 do
      # Empty graph — run is already complete, broadcast immediately
      summary =
        case DxCore.Core.Scheduler.whereis(nil, session_id, run_id) do
          nil -> DxCore.Core.RunSummary.empty()
          scheduler -> DxCore.Core.Scheduler.summary(scheduler)
        end

      @endpoint.broadcast!(socket.assigns.dispatcher_topic, "run_complete", %{
        "run_id" => run_id,
        "status" => "complete",
        "summary" => DxCore.Core.RunSummary.serialize(summary)
      })

      Sessions.mark_run_complete(session_id, run_id)
    else
      # Carry the scheduler pid + run_id so agents skip the registry lookup.
      # Symmetric with SaaS (#2143); on OSS this is single-node so there's no
      # race, but keeping the broadcast shape uniform means both coordinators
      # share one `tasks_available` payload contract.
      DxCore.Agents.Web.Endpoint.broadcast!(socket.assigns.agent_topic, "tasks_available", %{
        scheduler_pid: scheduler_pid,
        run_id: run_id
      })
    end

    {:reply,
     {:ok,
      %{
        "run_id" => run_id,
        "total_tasks" => total_tasks,
        "cached_tasks" => cached_tasks
      }}, socket}
  end
end
