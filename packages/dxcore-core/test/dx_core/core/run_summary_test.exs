defmodule DxCore.Core.RunSummaryTest do
  use ExUnit.Case, async: true

  alias DxCore.Core.RunSummary

  describe "empty/0" do
    test "returns a complete summary with zeroed counts" do
      summary = RunSummary.empty()
      assert summary.status == :complete
      assert summary.tasks == []
      assert summary.counts == %{passed: 0, failed: 0, skipped: 0, cached: 0}
      assert summary.failures == []
    end
  end

  describe "serialize/1" do
    test "serializes all task status atoms to strings" do
      summary = %{
        status: :failed,
        tasks: [
          %{
            task_id: "a#lint",
            package: "a",
            task: "lint",
            status: :done,
            cached: false,
            agent_id: "agent-1",
            duration_ms: 100,
            exit_code: 0
          },
          %{
            task_id: "a#build",
            package: "a",
            task: "build",
            status: :failed,
            cached: false,
            agent_id: "agent-2",
            duration_ms: 200,
            exit_code: 1
          },
          %{
            task_id: "a#test",
            package: "a",
            task: "test",
            status: :skipped,
            cached: false,
            agent_id: nil,
            duration_ms: nil,
            exit_code: nil
          },
          %{
            task_id: "a#deploy",
            package: "a",
            task: "deploy",
            status: :done,
            cached: true,
            agent_id: nil,
            duration_ms: nil,
            exit_code: nil
          }
        ],
        counts: %{passed: 1, failed: 1, skipped: 1, cached: 1},
        failures: [
          %{
            task_id: "a#build",
            agent_id: "agent-2",
            duration_ms: 200,
            exit_code: 1,
            output: "error"
          }
        ]
      }

      result = RunSummary.serialize(summary)

      assert result["status"] == "failed"
      statuses = Enum.map(result["tasks"], & &1["status"])
      assert statuses == ["done", "failed", "skipped", "done"]
    end

    test "nil output defaults to empty string" do
      summary = %{
        status: :failed,
        tasks: [],
        counts: %{passed: 0, failed: 1, skipped: 0, cached: 0},
        failures: [
          %{task_id: "a#lint", agent_id: "agent-1", duration_ms: 100, exit_code: 1}
        ]
      }

      result = RunSummary.serialize(summary)
      assert hd(result["failures"])["output"] == ""
    end

    test "nil duration_ms and exit_code are preserved" do
      summary = %{
        status: :running,
        tasks: [
          %{
            task_id: "a#lint",
            package: "a",
            task: "lint",
            status: :pending,
            cached: false,
            agent_id: nil,
            duration_ms: nil,
            exit_code: nil
          }
        ],
        counts: %{passed: 0, failed: 0, skipped: 0, cached: 0},
        failures: []
      }

      result = RunSummary.serialize(summary)
      task = hd(result["tasks"])
      assert task["duration_ms"] == nil
      assert task["exit_code"] == nil
    end

    test "counts map keys are all present" do
      summary = %{
        status: :complete,
        tasks: [],
        counts: %{passed: 3, failed: 1, skipped: 2, cached: 1},
        failures: []
      }

      result = RunSummary.serialize(summary)
      counts = result["counts"]
      assert counts["passed"] == 3
      assert counts["failed"] == 1
      assert counts["skipped"] == 2
      assert counts["cached"] == 1
    end
  end
end
