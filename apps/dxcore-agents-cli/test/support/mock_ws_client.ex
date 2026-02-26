defmodule DxCore.Agents.Test.MockWsClient do
  @moduledoc false

  @doc """
  Spawns a process that acts as a mock WsClient.

  Replies :ok to GenServer.call messages and forwards all messages to
  the test process for assertion:

    - `{:ws_call, msg}` for GenServer.call messages
    - `{:ws_cast, msg}` for GenServer.cast messages
  """
  def spawn_link(test_pid \\ self()) do
    Kernel.spawn_link(fn -> loop(test_pid) end)
  end

  defp loop(test_pid) do
    receive do
      {:"$gen_call", from, msg} ->
        GenServer.reply(from, :ok)
        send(test_pid, {:ws_call, msg})

      {:"$gen_cast", msg} ->
        send(test_pid, {:ws_cast, msg})
    end

    loop(test_pid)
  end
end
