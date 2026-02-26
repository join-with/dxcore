defmodule DxCore.Core.AgentInfo do
  @moduledoc "Describes the capabilities and identity of a connected build agent."

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
