defmodule DxCore.Agents.CLI.LostCoordinator do
  @moduledoc """
  How long an agent that lost the coordinator keeps its task, and so how long
  the coordinator must hold that task for it.

  From the moment its connection drops, the agent:

    1. retries the connection for `reconnect_timeout_ms/0`;
    2. lets its running task go on for `task_grace_ms/0` more, since killing
       a task mid-way (a `pulumi up`) leaves half-applied state;
    3. sends the task SIGTERM, and SIGKILL `kill_after_ms/0` later if it is
       still running;
    4. once the task has ended, reconnects for up to `reconnect_timeout_ms/0`
       to report its result.

  The task can be running for steps 1 to 3 only, so the coordinator's hold on
  a dropped agent's task (`DxCore.Core.Scheduler`'s `@default_lease_grace_ms`,
  in another package) must be at least `lease_needed_ms/0`: shorter, and a
  second agent can start the task while this one still runs it. A test reads
  the scheduler's source and fails when the two drift apart.
  """

  @reconnect_timeout_ms 30_000
  @task_grace_ms 90_000
  @kill_after_ms 60_000

  @doc "How long the WebSocket client retries a dropped connection."
  def reconnect_timeout_ms, do: @reconnect_timeout_ms

  @doc "How long a running task goes on after the reconnect window, before SIGTERM."
  def task_grace_ms, do: @task_grace_ms

  @doc "How long after SIGTERM a task that is still running gets SIGKILL."
  def kill_after_ms, do: @kill_after_ms

  @doc """
  The shortest hold that keeps a dropped agent's task off every other agent
  until this agent has stopped it and had its reconnect window to report it.
  """
  def lease_needed_ms,
    do: @reconnect_timeout_ms + @task_grace_ms + @kill_after_ms + @reconnect_timeout_ms
end
