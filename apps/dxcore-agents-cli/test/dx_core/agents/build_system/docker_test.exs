defmodule DxCore.Agents.BuildSystem.DockerTest do
  use ExUnit.Case, async: false

  alias DxCore.Agents.BuildSystem.Docker

  @fixture_path "test/fixtures/docker_bake.json"

  describe "parse_graph/1" do
    setup do
      json = File.read!(Path.join(File.cwd!(), @fixture_path))
      {:ok, json: json}
    end

    test "parses bake output into normalized task maps", %{json: json} do
      assert {:ok, tasks} = Docker.parse_graph(json)
      assert length(tasks) == 3

      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      api = by_id["api"]
      assert api["task"] == "build"
      assert api["package"] == "api"
      assert api["hash"] == ""
      assert api["cache"] == %{"status" => "MISS"}
    end

    test "extracts dependencies from contexts with target: prefix", %{json: json} do
      assert {:ok, tasks} = Docker.parse_graph(json)
      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      assert by_id["api"]["dependencies"] == []
      assert by_id["worker"]["dependencies"] == []
      assert by_id["gateway"]["dependencies"] == ["api"]
    end

    test "computes dependents from dependencies (inverse mapping)", %{json: json} do
      assert {:ok, tasks} = Docker.parse_graph(json)
      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      assert by_id["api"]["dependents"] == ["gateway"]
      assert by_id["worker"]["dependents"] == []
      assert by_id["gateway"]["dependents"] == []
    end

    test "sets hash to empty string and cache to MISS for all tasks", %{json: json} do
      assert {:ok, tasks} = Docker.parse_graph(json)

      Enum.each(tasks, fn task ->
        assert task["hash"] == ""
        assert task["cache"] == %{"status" => "MISS"}
      end)
    end

    test "handles bake output with no targets" do
      json = ~s({"group":{},"target":{}})
      assert {:ok, []} = Docker.parse_graph(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, msg} = Docker.parse_graph("not json")
      assert msg =~ "Failed to parse Docker bake JSON:"
    end

    test "returns error for JSON missing target key" do
      assert {:error, "Unexpected Docker bake output: missing target key"} =
               Docker.parse_graph(~s({"group":{}}))
    end

    test "marks targets without remote cache as not cacheable", %{json: json} do
      assert {:ok, tasks} = Docker.parse_graph(json)

      Enum.each(tasks, fn task ->
        assert task["cacheable"] == false
      end)
    end

    test "marks targets with cache-from as cacheable" do
      json =
        Jason.encode!(%{
          "target" => %{
            "api" => %{
              "dockerfile" => "Dockerfile",
              "context" => ".",
              "tags" => ["img:latest"],
              "cache-from" => ["type=registry,ref=ghcr.io/org/api:cache"]
            }
          }
        })

      assert {:ok, [task]} = Docker.parse_graph(json)
      assert task["cacheable"] == true
    end

    test "marks targets with empty cache-from as not cacheable" do
      json =
        Jason.encode!(%{
          "target" => %{
            "api" => %{
              "dockerfile" => "Dockerfile",
              "context" => ".",
              "tags" => ["img:latest"],
              "cache-from" => []
            }
          }
        })

      assert {:ok, [task]} = Docker.parse_graph(json)
      assert task["cacheable"] == false
    end

    test "builds command string from target metadata", %{json: json} do
      assert {:ok, tasks} = Docker.parse_graph(json)
      by_id = Map.new(tasks, fn t -> {t["taskId"], t} end)

      assert by_id["api"]["command"] ==
               "docker buildx build -f services/api/Dockerfile -t myrepo/api:latest -t myrepo/api:v1.2.3 --push services/api"

      assert by_id["worker"]["command"] ==
               "docker buildx build -f services/worker/Dockerfile -t myrepo/worker:latest --push services/worker"

      assert by_id["gateway"]["command"] ==
               "docker buildx build -f services/gateway/Dockerfile -t myrepo/gateway:latest --push services/gateway"
    end
  end
end
