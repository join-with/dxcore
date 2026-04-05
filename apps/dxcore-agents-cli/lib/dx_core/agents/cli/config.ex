defmodule DxCore.Agents.CLI.Config do
  @moduledoc false

  @shortdoc "Inspect shard configuration"
  @help """
  Inspect shard configuration.

  Usage: dxcore config [options]

  Options:
    --work-dir, -w <path>    Working directory to scan (default: ".")

  Scans for dxcore.json files and displays resolved shard configuration.\
  """

  use DxCore.Agents.CLI.Command

  def run([flag | _]) when flag in ["--help", "-h"] do
    DxCore.Agents.CLI.Help.print_for(__MODULE__)
    throw(:help)
  end

  def run(args) do
    opts = parse_args(args)
    work_dir = Keyword.get(opts, :work_dir, ".")
    config = DxCore.Agents.ShardConfig.scan(work_dir)

    case DxCore.Agents.ShardConfig.format_summary(config) do
      [] ->
        IO.puts("No shard configuration found. Add dxcore.json files to package directories.")

      lines ->
        IO.puts("Shard configuration:")
        Enum.each(lines, &IO.puts("  #{&1}"))
    end
  end

  @doc false
  def parse_args(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [work_dir: :string], aliases: [w: :work_dir])
    opts
  end
end
