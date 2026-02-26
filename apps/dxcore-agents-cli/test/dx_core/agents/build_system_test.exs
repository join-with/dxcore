defmodule DxCore.Agents.BuildSystemTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.BuildSystem

  describe "resolve/1" do
    test "resolves turbo to Turbo adapter" do
      assert {:ok, DxCore.Agents.BuildSystem.Turbo} = BuildSystem.resolve("turbo")
    end

    test "resolves nx to Nx adapter" do
      assert {:ok, DxCore.Agents.BuildSystem.Nx} = BuildSystem.resolve("nx")
    end

    test "returns error for unknown build system" do
      assert {:error, "Unknown build system: bazel"} = BuildSystem.resolve("bazel")
    end
  end
end
