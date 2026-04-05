defmodule DxCore.Agents.CLI.ConfigTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.CLI.Config

  describe "shortdoc/0" do
    test "returns a non-empty string" do
      assert is_binary(Config.shortdoc())
      assert Config.shortdoc() != ""
    end
  end

  describe "help/0" do
    test "returns usage text" do
      help = Config.help()
      assert is_binary(help)
      assert help =~ "Usage: dxcore config"
      assert help =~ "--work-dir"
    end
  end

  describe "parse_args/1" do
    test "parses --work-dir flag" do
      opts = Config.parse_args(["--work-dir", "/some/path"])
      assert Keyword.fetch!(opts, :work_dir) == "/some/path"
    end

    test "parses -w short alias" do
      opts = Config.parse_args(["-w", "/other/path"])
      assert Keyword.fetch!(opts, :work_dir) == "/other/path"
    end

    test "returns empty keyword list for empty args" do
      opts = Config.parse_args([])
      assert opts == []
    end
  end
end
