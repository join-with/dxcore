defmodule DxCore.Agents.Web.DispatcherSocket do
  use Phoenix.Socket

  channel "dispatcher:*", DxCore.Agents.Web.DispatcherChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case DxCore.Agents.Tenants.verify_token(token) do
      {:ok, scope} -> {:ok, assign(socket, :current_scope, scope)}
      :error -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
