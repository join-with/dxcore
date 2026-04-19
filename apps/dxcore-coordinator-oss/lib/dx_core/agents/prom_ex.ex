defmodule DxCore.Agents.PromEx do
  use JwObservability.PromEx,
    otp_app: :dxcore_coordinator_oss,
    router: DxCore.Agents.Web.Router,
    repo: nil
end
