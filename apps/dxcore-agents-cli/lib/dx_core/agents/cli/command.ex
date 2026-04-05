defmodule DxCore.Agents.CLI.Command do
  @moduledoc false
  @callback shortdoc() :: String.t()
  @callback help() :: String.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour DxCore.Agents.CLI.Command

      @impl true
      def shortdoc, do: @shortdoc
      @impl true
      def help, do: @help
    end
  end
end
