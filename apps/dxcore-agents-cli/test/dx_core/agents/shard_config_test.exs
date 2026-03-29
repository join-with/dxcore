defmodule DxCore.Agents.ShardConfigTest do
  use ExUnit.Case, async: false

  alias DxCore.Agents.ShardConfig

  @tmp_dir "test/tmp/shard_config_test"

  setup do
    base = Path.expand(@tmp_dir, File.cwd!())
    File.rm_rf!(base)
    File.mkdir_p!(base)

    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, base: base}
  end

  describe "scan/1" do
    test "reads shard config from a single dxcore.json", %{base: base} do
      pkg_dir = Path.join(base, "apps/e2e-app")
      File.mkdir_p!(pkg_dir)
      File.write!(Path.join(pkg_dir, "dxcore.json"), ~s({"shards": {"test": 4}}))

      assert ShardConfig.scan(base) == %{"e2e-app#test" => 4}
    end

    test "merges configs from multiple packages in different subdirectories", %{base: base} do
      apps_e2e = Path.join(base, "apps/e2e-app")
      apps_web = Path.join(base, "apps/web-app")
      pkgs_ui = Path.join(base, "packages/ui")

      File.mkdir_p!(apps_e2e)
      File.mkdir_p!(apps_web)
      File.mkdir_p!(pkgs_ui)

      File.write!(Path.join(apps_e2e, "dxcore.json"), ~s({"shards": {"test": 4}}))
      File.write!(Path.join(apps_web, "dxcore.json"), ~s({"shards": {"test": 2, "build": 1}}))
      File.write!(Path.join(pkgs_ui, "dxcore.json"), ~s({"shards": {"lint": 3}}))

      result = ShardConfig.scan(base)

      assert result == %{
               "e2e-app#test" => 4,
               "web-app#test" => 2,
               "web-app#build" => 1,
               "ui#lint" => 3
             }
    end

    test "returns empty map when no dxcore.json files exist", %{base: base} do
      assert ShardConfig.scan(base) == %{}
    end

    test "ignores dxcore.json with invalid JSON", %{base: base} do
      pkg_dir = Path.join(base, "apps/broken-app")
      File.mkdir_p!(pkg_dir)
      File.write!(Path.join(pkg_dir, "dxcore.json"), "this is not json {{")

      assert ShardConfig.scan(base) == %{}
    end

    test "ignores dxcore.json without shards key", %{base: base} do
      pkg_dir = Path.join(base, "apps/no-shards-app")
      File.mkdir_p!(pkg_dir)
      File.write!(Path.join(pkg_dir, "dxcore.json"), ~s({"version": "1.0", "tasks": []}))

      assert ShardConfig.scan(base) == %{}
    end

    test "filters out non-integer shard values", %{base: base} do
      pkg_dir = Path.join(base, "apps/bad-values-app")
      File.mkdir_p!(pkg_dir)

      File.write!(
        Path.join(pkg_dir, "dxcore.json"),
        ~s({"shards": {"test": "four", "build": 3, "lint": null, "e2e": 2}})
      )

      assert ShardConfig.scan(base) == %{"bad-values-app#build" => 3, "bad-values-app#e2e" => 2}
    end

    test "filters out non-positive shard values", %{base: base} do
      pkg_dir = Path.join(base, "apps/zero-app")
      File.mkdir_p!(pkg_dir)

      File.write!(
        Path.join(pkg_dir, "dxcore.json"),
        ~s({"shards": {"test": 0, "build": -1, "lint": 2}})
      )

      assert ShardConfig.scan(base) == %{"zero-app#lint" => 2}
    end
  end

  describe "format_summary/1" do
    test "formats config as sorted human-readable lines" do
      config = %{
        "e2e-app#test" => 4,
        "web-app#test" => 2,
        "alpha-app#build" => 1
      }

      assert ShardConfig.format_summary(config) == [
               "alpha-app#build: 1 shards",
               "e2e-app#test: 4 shards",
               "web-app#test: 2 shards"
             ]
    end

    test "returns empty list for empty config" do
      assert ShardConfig.format_summary(%{}) == []
    end
  end
end
