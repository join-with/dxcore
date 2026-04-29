defmodule DxCore.Core.AgentInfoTest do
  use ExUnit.Case, async: true

  alias DxCore.Core.AgentInfo

  describe "Jason.Encoder" do
    # Regression gate for the production crash discovered after #2110 rolled
    # out: Presence.track puts %AgentInfo{} into metadata, and the WebSocket
    # serializer JSON-encodes every presence_diff. Without @derive, the
    # encoder protocol raises and Phoenix.Tracker's shard GenServer crashes
    # on every agent join, taking the whole presence-tracking subsystem
    # offline.
    test "encodes a populated struct" do
      info = %AgentInfo{
        agent_id: "agent-1",
        cpu_cores: 16,
        memory_mb: 32_000,
        disk_free_mb: 1_000_000,
        tags: %{"runner" => "linux"},
        connected_at: ~U[2026-04-29 10:00:00Z]
      }

      assert {:ok, json} = Jason.encode(info)

      decoded = Jason.decode!(json)

      assert decoded["agent_id"] == "agent-1"
      assert decoded["cpu_cores"] == 16
      assert decoded["memory_mb"] == 32_000
      assert decoded["tags"] == %{"runner" => "linux"}
    end

    test "encodes a struct with nil fields (default constructor case)" do
      assert {:ok, _json} = Jason.encode(%AgentInfo{})
    end

    test "round-trips through a Presence-style metadata map" do
      # Mirrors the shape Phoenix.Presence.track/3 receives in
      # `apps/dxcore-coordinator-saas/lib/dx_core/saas/web/channels/agent_channel.ex`.
      info = %AgentInfo{agent_id: "agent-1", tags: %{"zig" => "true"}}

      meta = %{
        joined_at: 1_234_567_890,
        agent_info: info
      }

      assert {:ok, _json} = Jason.encode(meta)
    end
  end
end
