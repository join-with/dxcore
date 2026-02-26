defmodule DxCore.Core.ChannelHelpers do
  @moduledoc """
  Shared helpers for agent channel implementations (OSS and SaaS).

  Provides common task assignment, log forwarding, and lifecycle logic
  that both coordinator variants share.

  ## Usage

      use DxCore.Core.ChannelHelpers, endpoint: MyApp.Web.Endpoint

  This injects `try_assign_task/1` and `handle_disconnect/1` as private
  functions into the using module, bound to the given endpoint. These
  functions call `push/3` and `assign/3` which must be available in the
  using module (i.e. it must be a Phoenix Channel).

  `get_run_id/1` is a regular function — call it as
  `DxCore.Core.ChannelHelpers.get_run_id(scheduler)`.
  """

  alias DxCore.Core.Scheduler

  @doc """
  Safely retrieves the run_id from a scheduler process.
  Returns nil if the scheduler is no longer alive.
  """
  def get_run_id(scheduler) do
    if Process.alive?(scheduler) do
      status = Scheduler.status(scheduler)
      status.run_id
    else
      nil
    end
  end

  defmacro __using__(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)

    quote do
      @__channel_endpoint unquote(endpoint)

      defp try_assign_task(socket) do
        agent_id = socket.assigns.agent_id
        session_id = socket.assigns.session_id
        agent_info = socket.assigns.agent_info

        scheduler_pids = DxCore.Core.Scheduler.list_for_session(session_id)

        result =
          Enum.find_value(scheduler_pids, fn {pid, run_id} ->
            case DxCore.Core.Scheduler.request_task(pid, agent_id, agent_info) do
              {:ok, task} -> {pid, run_id, task}
              :no_task -> nil
            end
          end)

        case result do
          {pid, run_id, task} ->
            push(socket, "assign_task", %{
              "task_id" => task.task_id,
              "package" => task.package,
              "task" => task.task,
              "hash" => task.hash,
              "shard" => task.shard
            })

            @__channel_endpoint.broadcast!("dispatcher:#{session_id}", "task_started", %{
              "task_id" => task.task_id,
              "agent_id" => agent_id
            })

            socket
            |> assign(:current_scheduler, pid)
            |> assign(:current_run_id, run_id)

          nil ->
            socket
        end
      end

      defp handle_disconnect(socket) do
        session_id = socket.assigns[:session_id]
        agent_id = socket.assigns[:agent_id]

        if agent_id do
          if session_id do
            @__channel_endpoint.broadcast!(
              "dispatcher:#{session_id}",
              "agent_disconnected",
              %{"agent_id" => agent_id}
            )
          end

          case socket.assigns[:current_scheduler] do
            nil -> :ok
            scheduler -> DxCore.Core.Scheduler.reassign_task(scheduler, agent_id)
          end

          if session_id do
            @__channel_endpoint.broadcast!("agent:#{session_id}", "tasks_available", %{})
          end
        end

        :ok
      end
    end
  end
end
