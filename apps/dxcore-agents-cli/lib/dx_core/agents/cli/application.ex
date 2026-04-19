defmodule DxCore.Agents.CLI.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Prevent Logger.Formatter crash on SSL alert report_cb
    # (see elixir-lang/elixir#14020, joinwith#1799)
    case :logger.add_primary_filter(:ssl_alert_guard, {&__MODULE__.filter_ssl_alerts/2, []}) do
      :ok ->
        :ok

      {:error, :already_exist} ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Failed to register ssl_alert_guard filter: #{inspect(reason)}")
    end

    children = []
    opts = [strategy: :one_for_one, name: DxCore.Agents.CLI.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # When running as a Burrito binary, dispatch CLI command
    if Burrito.Util.running_standalone?() do
      Task.start_link(fn ->
        try do
          args = Burrito.Util.Args.argv()
          DxCore.Agents.CLI.main(args)
          System.halt(0)
        rescue
          e ->
            IO.puts(:stderr, Exception.format(:error, e, __STACKTRACE__))
            System.halt(1)
        end
      end)
    end

    {:ok, pid}
  end

  @doc false
  def filter_ssl_alerts(
        %{meta: %{domain: [:otp, :ssl | _], report_cb: cb} = meta} = event,
        _config
      )
      when is_function(cb, 1) do
    safe_cb = fn data ->
      try do
        cb.(data)
      catch
        _, _ -> {"SSL: ~p", [data]}
      end
    end

    %{event | meta: %{meta | report_cb: safe_cb}}
  end

  def filter_ssl_alerts(
        %{meta: %{domain: [:otp, :ssl | _], report_cb: cb} = meta} = event,
        _config
      )
      when is_function(cb, 2) do
    safe_cb = fn data, config ->
      try do
        cb.(data, config)
      catch
        _, _ -> "SSL: #{inspect(data)}"
      end
    end

    %{event | meta: %{meta | report_cb: safe_cb}}
  end

  def filter_ssl_alerts(event, _config), do: event
end
