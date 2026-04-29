defmodule DxCore.Core.AgentInfo do
  @moduledoc """
  Describes the capabilities and identity of a connected build agent.

  Encodable to JSON via `@derive Jason.Encoder` because instances ride in
  `Phoenix.Presence` metadata under `agent:<org>:<session>` topics
  (#2110), and Phoenix.Channel.Server's WebSocket serializer JSON-encodes
  every `presence_diff` payload it forwards to subscribers. Without
  `@derive`, `Phoenix.Presence`'s tracker shard crashes on every agent
  join (the encoder protocol raises) — caught in production after #2110
  rolled out and now gated by `AgentInfoTest`.
  """

  @derive Jason.Encoder

  @type t :: %__MODULE__{
          agent_id: String.t() | nil,
          cpu_cores: non_neg_integer() | nil,
          memory_mb: non_neg_integer() | nil,
          disk_free_mb: non_neg_integer() | nil,
          tags: map() | nil,
          connected_at: DateTime.t() | nil
        }

  defstruct [:agent_id, :cpu_cores, :memory_mb, :disk_free_mb, :tags, :connected_at]
end
