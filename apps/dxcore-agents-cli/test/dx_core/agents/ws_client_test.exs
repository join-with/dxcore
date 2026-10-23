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

  describe "join params" do
    defp connected_socket(topic) do
      %Socket{
        channel_pid: self(),
        socket_pid: self(),
        assigns: %{
          topic: topic,
          caller: self(),
          pending_replies: %{},
          reconnect_deadline: nil,
          join_params: %{}
        },
        metadata: %{joins: %{}},
        joins: %{}
      }
    end

    defp joined_params do
      receive do
        {:__slipstream_command__, %Slipstream.Commands.JoinTopic{payload: payload}} -> payload
      after
        500 -> flunk("no JoinTopic command was sent")
      end
    end

    test "a join sends no params until they are set, then every rejoin sends them" do
      topic = "dispatcher:org:run-1"
      socket = connected_socket(topic)

      assert {:ok, _} = WsClient.handle_connect(socket)
      assert joined_params() == %{}

      assert {:noreply, socket} =
               WsClient.handle_cast({:set_join_params, %{"resume" => true}}, socket)

      assert {:ok, _} = WsClient.handle_connect(socket)
      assert joined_params() == %{"resume" => true}
    end
  end

  describe "handle_topic_close/3" do
    defp closed_socket(topic) do
      %Socket{
        channel_pid: self(),
        socket_pid: self(),
        channel_config: %Slipstream.Configuration{
          uri: URI.parse("ws://x"),
          rejoin_after_msec: [0]
        },
        assigns: %{
          topic: topic,
          caller: self(),
          pending_replies: %{},
          join_params: %{"resume" => true}
        },
        joins: %{topic => %Join{topic: topic, status: :closed, params: %{}, rejoin_counter: 0}}
      }
    end

    test "a channel that crashed on the server is rejoined with the current join params" do
      topic = "dispatcher:org:run-1"

      assert {:ok, _} = WsClient.handle_topic_close(topic, {:error, %{}}, closed_socket(topic))
      assert_receive {:topic_closed, ^topic, {:error, %{}}}

      assert_receive {:__slipstream_command__,
                      %Slipstream.Commands.JoinTopic{topic: ^topic, payload: %{"resume" => true}}},
                     500
    end

    test "a refused join is not retried" do
      topic = "dispatcher:org:run-1"
      reason = {:failed_to_join, %{"reason" => "run_not_found"}}

      assert {:ok, _} = WsClient.handle_topic_close(topic, reason, closed_socket(topic))
      assert_receive {:topic_closed, ^topic, ^reason}
      refute_receive {:__slipstream_command__, %Slipstream.Commands.JoinTopic{}}, 100
    end
  end
end
