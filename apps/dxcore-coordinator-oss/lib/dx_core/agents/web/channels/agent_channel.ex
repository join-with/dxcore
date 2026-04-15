defmodule DxCore.Agents.Web.AgentChannel do
  use DxCore.Agents.Web, :channel
  use DxCore.Core.ChannelHelpers, endpoint: DxCore.Agents.Web.Endpoint

  alias DxCore.Agents.{Scheduler, Sessions}

  @endpoint DxCore.Agents.Web.Endpoint

  intercept ["tasks_available"]

  @impl true
  def join("agent:" <> session_id, _params, socket) do
    if Sessions.session_finished?(session_id) do
      {:error, %{reason: "session_finished"}}
    else
      socket =
        assign(socket,
          session_id: session_id,
          dispatcher_topic: "dispatcher:#{session_id}",
          agent_topic: "agent:#{session_id}"
        )

      {:ok, socket}
    end
  end

  @impl true
  def handle_in("agent_ready", %{"agent_id" => agent_id} = payload, socket) do
    scope = socket.assigns.current_scope
    session_id = socket.assigns.session_id
    capabilities = payload["capabilities"] || %{}

    agent_info = %DxCore.Core.AgentInfo{
      agent_id: agent_id,
      cpu_cores: capabilities["cpu_cores"],
      memory_mb: capabilities["memory_mb"],
      disk_free_mb: capabilities["disk_free_mb"],
      tags: capabilities["tags"] || %{},
      connected_at: DateTime.utc_now()
    }

    socket =
      socket
      |> assign(:agent_id, agent_id)
      |> assign(:agent_info, agent_info)

    case Sessions.register_agent(scope, session_id, agent_id) do
      :ok ->
        DxCore.Agents.Web.Presence.track(socket, agent_id, %{
          joined_at: System.system_time(:second)
        })

        @endpoint.broadcast!(socket.assigns.dispatcher_topic, "agent_connected", %{
          "agent_id" => agent_id
        })

        socket = try_assign_task(socket)
        {:noreply, socket}

      {:error, :unauthorized} ->
        {:stop, :normal, socket}
    end
  end

  @impl true
  def handle_in("task_result", payload, socket) do
    %{"task_id" => task_id, "exit_code" => exit_code} = payload
    result = if exit_code == 0, do: {:success, exit_code}, else: {:failed, exit_code}
    scheduler = socket.assigns[:current_scheduler]
    run_id = socket.assigns[:current_run_id]
    session_id = socket.assigns.session_id

    {:ok, run_status} = Scheduler.report_result(scheduler, task_id, result)

    @endpoint.broadcast!(socket.assigns.dispatcher_topic, "task_completed", %{
      "task_id" => task_id,
      "agent_id" => socket.assigns[:agent_id],
      "exit_code" => exit_code,
      "duration_ms" => payload["duration_ms"]
    })

    # Clear current scheduler/run_id after reporting
    socket =
      socket
      |> assign(:current_scheduler, nil)
      |> assign(:current_run_id, nil)

    if run_status in [:complete, :failed] do
      run_id = run_id || DxCore.Core.ChannelHelpers.get_run_id(scheduler)

      scheduler_summary = Scheduler.summary(scheduler)

      failures_with_output =
        Enum.map(scheduler_summary.failures, fn failure ->
          output =
            DxCore.Core.TaskLogBuffer.get_output(
              :dxcore_oss_task_log_buffer,
              session_id,
              failure.task_id
            )

          Map.put(failure, :output, output)
        end)

      summary = %{scheduler_summary | failures: failures_with_output}
      DxCore.Core.TaskLogBuffer.cleanup(:dxcore_oss_task_log_buffer, session_id)

      @endpoint.broadcast!(socket.assigns.dispatcher_topic, "run_complete", %{
        "run_id" => run_id,
        "status" => to_string(run_status),
        "summary" => DxCore.Core.RunSummary.serialize(summary)
      })

      Sessions.mark_run_complete(session_id, run_id)

      socket = try_assign_task(socket)
      {:noreply, socket}
    else
      socket = try_assign_task(socket)
      {:noreply, socket}
    end
  end

  @impl true
  def handle_in("task_log", %{"task_id" => task_id, "line" => line}, socket) do
    session_id = socket.assigns.session_id
    agent_id = socket.assigns[:agent_id]

    @endpoint.broadcast!(socket.assigns.dispatcher_topic, "task_log", %{
      "agent_id" => agent_id,
      "task_id" => task_id,
      "line" => line
    })

    DxCore.Core.TaskLogBuffer.buffer(:dxcore_oss_task_log_buffer, session_id, task_id, line)

    {:noreply, socket}
  end

  @impl true
  def handle_in("heartbeat", _payload, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_out("tasks_available", _payload, socket) do
    socket =
      if socket.assigns[:agent_id] && socket.assigns[:current_scheduler] == nil do
        try_assign_task(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    session_id = socket.assigns[:session_id]
    agent_id = socket.assigns[:agent_id]

    if agent_id && session_id do
      Sessions.unregister_agent(session_id, agent_id)
    end

    handle_disconnect(socket)
  end
end
