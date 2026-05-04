defmodule DxCore.Agents.WsClientTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.WsClient
  alias Slipstream.Socket
  alias Slipstream.Socket.Join

  # Builds a Slipstream.Socket struct with a "dying" channel_pid that mimics
  # slipstream's connection process during a graceful close: it accepts the
  # GenServer.call from Slipstream.push but exits :normal without replying.
  # This reproduces the race observed in production when a coordinator pod
  # closes the WebSocket while a {:push, ...} cast is in flight (#2357).
  defp socket_with_dying_channel(topic) do
    dying_pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, _msg} -> :ok
        end
      end)

    %Socket{
      channel_pid: dying_pid,
      socket_pid: self(),
      assigns: %{
        topic: topic,
        pending_replies: %{}
      },
      joins: %{
        topic => %Join{
          topic: topic,
          status: :joined,
          params: %{},
          rejoin_counter: 0
        }
      }
    }
  end

  describe "handle_cast/2 :push" do
    test "survives transport process exiting :normal mid-push (no GenServer crash)" do
      topic = "agent:test"
      socket = socket_with_dying_channel(topic)

      result =
        try do
          WsClient.handle_cast(
            {:push, "task_log", %{"line" => "", "task_id" => "@repo/example#release"}},
            socket
          )
        catch
          :exit, reason -> {:caught_exit, reason}
        end

      assert {:noreply, ^socket} = result
    end
  end

  describe "handle_call/3 :push_and_wait" do
    test "replies with error instead of crashing when transport exits :normal mid-push" do
      topic = "agent:test"
      socket = socket_with_dying_channel(topic)
      from = {self(), make_ref()}

      result =
        try do
          WsClient.handle_call({:push_and_wait, "task_log", %{"line" => ""}}, from, socket)
        catch
          :exit, reason -> {:caught_exit, reason}
        end

      assert {:reply, {:error, _reason}, ^socket} = result
    end
  end
end
