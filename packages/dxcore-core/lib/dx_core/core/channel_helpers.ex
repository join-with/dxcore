defmodule DxCore.Core.ChannelHelpers do
  @moduledoc """
  Shared helpers for agent channel implementations (OSS and SaaS).

  Provides common task assignment, log forwarding, and lifecycle logic
  that both coordinator variants share.

  ## Usage

      use DxCore.Core.ChannelHelpers, endpoint: MyApp.Web.Endpoint

  This injects `try_assign_task/1`, `try_assign_task/2`, and
  `handle_disconnect/1` as private functions into the using module, bound
  to the given endpoint. These functions call `push/3` and `assign/3`
  which must be available in the using module (i.e. it must be a Phoenix
  Channel).

  `try_assign_task/2` accepts an optional `{scheduler_pid, run_id}` hint
  carried in the `tasks_available` broadcast payload. When provided, the
  helper skips the `Horde.Registry`-backed `Scheduler.list_for_session/2`
  lookup and calls `Scheduler.request_task/3` directly on the supplied
  pid. This closes the cross-pod race documented in #2143 where a
  newly-registered Scheduler is not yet visible in a remote pod's local
  CRDT view by the time the `tasks_available` broadcast arrives there.

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

      defp try_assign_task(socket, scheduler_hint \\ nil) do
        agent_id = socket.assigns.agent_id
        session_id = socket.assigns.session_id
        agent_info = socket.assigns.agent_info
        fallback_dispatcher_topic = socket.assigns.dispatcher_topic
        # OSS sockets do not set `:org_id`; the registry key falls back to
        # `nil` and matches the OSS bucket. SaaS sockets set the connected
        # organization's id at join time so the scan stays org-scoped.
        org_id = socket.assigns[:org_id]

        scheduler_pids =
          case scheduler_hint do
            {pid, run_id} when is_pid(pid) -> [{pid, run_id}]
            _ -> DxCore.Core.Scheduler.list_for_session(org_id, session_id)
          end

        result =
          Enum.find_value(scheduler_pids, fn {pid, run_id} ->
            case safe_request_task(pid, agent_id, agent_info) do
              {:ok, task} -> {pid, run_id, task}
              _ -> nil
            end
          end)

        case result do
          {pid, run_id, task} ->
            push(socket, "assign_task", %{
              "task_id" => task.task_id,
              "run_id" => run_id,
              "package" => task.package,
              "task" => task.task,
              "hash" => task.hash,
              "command" => task.command,
              "shard" => task.shard
            })

            # Prefer the scheduler's own dispatcher_topic — for SaaS this is the
            # run-scoped topic set during submit_graph/rehydration; for OSS the
            # scheduler stores no topic and we fall back to the session-scoped
            # one on the socket.
            run_scoped_topic =
              case DxCore.Core.Scheduler.dispatcher_topic(pid) do
                nil -> fallback_dispatcher_topic
                topic -> topic
              end

            @__channel_endpoint.broadcast!(run_scoped_topic, "task_started", %{
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
        agent_id = socket.assigns[:agent_id]

        if agent_id do
          if dispatcher_topic = socket.assigns[:dispatcher_topic] do
            @__channel_endpoint.broadcast!(
              dispatcher_topic,
              "agent_disconnected",
              %{"agent_id" => agent_id}
            )
          end

          case socket.assigns[:current_scheduler] do
            nil -> :ok
            scheduler -> DxCore.Core.Scheduler.reassign_task(scheduler, agent_id)
          end

          # Notify schedulers of topology change
          for {pid, _run_id} <-
                DxCore.Core.Scheduler.list_for_session(
                  socket.assigns[:org_id],
                  socket.assigns[:session_id] || ""
                ) do
            DxCore.Core.Scheduler.check_topology(pid)
          end

          if agent_topic = socket.assigns[:agent_topic] do
            @__channel_endpoint.broadcast!(agent_topic, "tasks_available", %{})
          end
        end

        :ok
      end

      # Wraps `Scheduler.request_task/3` so a dead pid (e.g. a stale hint
      # carried in a delayed broadcast) does not exit the channel process.
      # Falls through to `:no_task` and the caller drops to the empty
      # result, leaving the existing `tasks_available` flow to retry on the
      # next broadcast.
      defp safe_request_task(pid, agent_id, agent_info) do
        DxCore.Core.Scheduler.request_task(pid, agent_id, agent_info)
      catch
        :exit, _ -> :no_task
      end
    end
  end
end
