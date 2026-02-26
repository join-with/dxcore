defmodule DxCore.Agents.CLI.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
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
end
