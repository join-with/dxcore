defmodule DxCore.Agents.CLI.HelpTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias DxCore.Agents.CLI.Help

  describe "print_top_level/0" do
    test "prints tagline, usage, all 4 commands, and footer" do
      output = capture_io(fn -> Help.print_top_level() end)

      assert output =~ "dxcore - Distributed CI/CD task execution for monorepos"
      assert output =~ "Usage: dxcore <command> [options]"
      assert output =~ "agent"
      assert output =~ "dispatch"
      assert output =~ "ci"
      assert output =~ "config"
      assert output =~ "Run 'dxcore <command> --help' for more information."
    end
  end

  describe "print_for/1" do
    defmodule FakeCommand do
      @help "Fake command help text.\n\nUsage: dxcore fake [options]"
      def help, do: @help
    end

    test "prints the help text from the given module" do
      output = capture_io(fn -> Help.print_for(FakeCommand) end)

      assert output =~ "Fake command help text."
      assert output =~ "Usage: dxcore fake [options]"
    end
  end

  describe "binary rename" do
    test "no dxcore-agents references remain in help output" do
      output = capture_io(fn -> Help.print_top_level() end)
      refute output =~ "dxcore-agents"
    end

    test "dispatcher error message uses dxcore not dxcore-agents" do
      {:error, msg} = DxCore.Agents.CLI.Dispatcher.read_stdin("", "turbo")
      refute msg =~ "dxcore-agents"
      assert msg =~ "dxcore dispatch"
    end
  end

  describe "help dispatch integration" do
    test "Agent.run with --help prints help and throws :help" do
      output =
        capture_io(fn ->
          assert catch_throw(DxCore.Agents.CLI.Agent.run(["--help"])) == :help
        end)

      assert output =~ "Usage: dxcore agent"
      assert output =~ "--coordinator"
    end

    test "Agent.run with -h prints help and throws :help" do
      output =
        capture_io(fn ->
          assert catch_throw(DxCore.Agents.CLI.Agent.run(["-h"])) == :help
        end)

      assert output =~ "Usage: dxcore agent"
    end

    test "Dispatcher.run with --help prints help and throws :help" do
      output =
        capture_io(fn ->
          assert catch_throw(DxCore.Agents.CLI.Dispatcher.run(["--help"])) == :help
        end)

      assert output =~ "Usage:"
      assert output =~ "dxcore dispatch"
    end

    test "Ci.run with --help prints help and throws :help" do
      output =
        capture_io(fn ->
          assert catch_throw(DxCore.Agents.CLI.Ci.run(["--help"])) == :help
        end)

      assert output =~ "Usage: dxcore ci"
      assert output =~ "create-session"
    end

    test "Config.run with --help prints help and throws :help" do
      output =
        capture_io(fn ->
          assert catch_throw(DxCore.Agents.CLI.Config.run(["--help"])) == :help
        end)

      assert output =~ "Usage: dxcore config"
    end
  end
end
