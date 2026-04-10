defmodule DxCore.Agents.CLI.CommandTemplateTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.CLI.CommandTemplate

  describe "interpolate/2" do
    test "interpolates all known placeholders" do
      template = "{package} {task} {hash} {shard_index} {shard_count} {command}"

      params = %{
        "package" => "web",
        "task" => "build",
        "hash" => "abc123",
        "shard_index" => "0",
        "shard_count" => "4",
        "command" => "npx turbo run build"
      }

      assert {:ok, "web build abc123 0 4 npx turbo run build"} =
               CommandTemplate.interpolate(template, params)
    end

    test "template with no placeholders returns as-is" do
      assert {:ok, "make all"} =
               CommandTemplate.interpolate("make all", %{
                 "package" => "web",
                 "task" => "build",
                 "hash" => "",
                 "shard_index" => nil,
                 "shard_count" => nil,
                 "command" => "echo hi"
               })
    end

    test "wraps original command via {command} placeholder" do
      params = %{
        "package" => "web",
        "task" => "build",
        "hash" => "",
        "shard_index" => nil,
        "shard_count" => nil,
        "command" => "npx turbo run build --filter=web"
      }

      assert {:ok, "timeout 300 npx turbo run build --filter=web"} =
               CommandTemplate.interpolate("timeout 300 {command}", params)
    end

    test "errors when used placeholder resolves to empty string" do
      params = %{
        "package" => "",
        "task" => "build",
        "hash" => "",
        "shard_index" => nil,
        "shard_count" => nil,
        "command" => ""
      }

      assert {:error, msg} = CommandTemplate.interpolate("make -C {package} {task}", params)
      assert msg =~ "package"
    end

    test "shard placeholders with nil values succeed when not used in template" do
      params = %{
        "package" => "web",
        "task" => "build",
        "hash" => "",
        "shard_index" => nil,
        "shard_count" => nil,
        "command" => ""
      }

      assert {:ok, "make -C web build"} =
               CommandTemplate.interpolate("make -C {package} {task}", params)
    end

    test "shard placeholders with nil values error when used in template" do
      params = %{
        "package" => "web",
        "task" => "build",
        "hash" => "",
        "shard_index" => nil,
        "shard_count" => nil,
        "command" => ""
      }

      assert {:error, msg} =
               CommandTemplate.interpolate("run {task} --shard {shard_index}", params)

      assert msg =~ "shard_index"
    end

    test "errors on unknown placeholder" do
      params = %{
        "package" => "web",
        "task" => "build",
        "hash" => "",
        "shard_index" => nil,
        "shard_count" => nil,
        "command" => ""
      }

      assert {:error, msg} = CommandTemplate.interpolate("make {foo}", params)
      assert msg =~ "foo"
    end

    test "errors when result is empty after interpolation" do
      params = %{
        "package" => "",
        "task" => "",
        "hash" => "",
        "shard_index" => nil,
        "shard_count" => nil,
        "command" => ""
      }

      assert {:error, _} = CommandTemplate.interpolate("{hash}", params)
    end
  end
end
