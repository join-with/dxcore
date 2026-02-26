defmodule DxCore.Agents.Web.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      @endpoint DxCore.Agents.Web.Endpoint
    end
  end

  setup _tags do
    :ok
  end
end
