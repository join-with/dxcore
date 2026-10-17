defmodule DxCore.Agents.Web.DispatcherSocketTest do
  use DxCore.Agents.Web.ChannelCase

  require Logger

  setup do
    {:ok, token} = DxCore.Agents.Tenants.create_tenant("test-tenant", "Test Tenant")
    %{token: token}
  end

  test "connect with valid token assigns current_scope", %{token: token} do
    assert {:ok, socket} = connect(DxCore.Agents.Web.DispatcherSocket, %{"token" => token})
    assert %DxCore.Agents.Scope{tenant_id: "test-tenant"} = socket.assigns.current_scope
  end

  test "connect without token returns error" do
    assert :error = connect(DxCore.Agents.Web.DispatcherSocket, %{})
  end

  test "connect with invalid token returns error" do
    assert :error = connect(DxCore.Agents.Web.DispatcherSocket, %{"token" => "bad-token"})
  end

  # The info-level connect log prints the connect params; a valid token in
  # it is a working tenant credential for anyone who reads the logs.
  for socket_module <- [DxCore.Agents.Web.AgentSocket, DxCore.Agents.Web.DispatcherSocket] do
    test "#{inspect(socket_module)}'s connect log shows the token as [FILTERED]", %{token: token} do
      # config/test.exs sets the level to :warning, and the connect log is :info.
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert {:ok, _socket} = connect(unquote(socket_module), %{"token" => token})
        end)

      assert log =~ "CONNECTED TO #{inspect(unquote(socket_module))}"
      assert log =~ ~s("token" => "[FILTERED]")
      refute log =~ token
    end
  end
end
