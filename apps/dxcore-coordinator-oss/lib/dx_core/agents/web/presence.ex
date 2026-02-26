defmodule DxCore.Agents.Web.Presence do
  @moduledoc """
  Phoenix Presence module for tracking connected agents.

  Used to detect agent disconnects so that in-progress tasks
  can be returned to the frontier for reassignment.
  """

  use Phoenix.Presence,
    otp_app: :dxcore_coordinator_oss,
    pubsub_server: DxCore.Agents.PubSub
end
