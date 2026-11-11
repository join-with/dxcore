defmodule DxCore.Agents.CLI.Dispatcher.ResultTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.CLI.Dispatcher.{Deadline, Result}

  @passed %{
    "result" => "passed",
    "total" => 40,
    "cached" => 10,
    "left" => 0,
    "failed" => 0,
    "failed_tasks" => []
  }

  test "parses the coordinator's result and drops unknown keys" do
    assert {:ok, @passed} = Result.parse(Map.put(@passed, "extra", 1))
  end

  test "refuses a missing or unknown verdict" do
    assert Result.parse(nil) == :error
    assert Result.parse(%{@passed | "result" => "maybe"}) == :error
    assert Result.parse(Map.delete(@passed, "failed")) == :error
  end

  test "the verdict maps to the CLI's exit codes" do
    assert Deadline.exit_code(Result.stop_reason(@passed)) == 0
    assert Deadline.exit_code(Result.stop_reason(%{@passed | "result" => "unfinished"})) == 75
    assert Deadline.exit_code(Result.stop_reason(%{@passed | "result" => "failed"})) == 1
  end

  test "the left line counts the tasks that had to run" do
    assert Result.left_line(%{@passed | "left" => 3}) == "3 of 30 tasks left"
  end

  @tag :tmp_dir
  test "writes the result as JSON, and nil writes nothing", %{tmp_dir: dir} do
    path = Path.join(dir, "result.json")
    assert Result.write(path, @passed) == :ok
    assert Jason.decode!(File.read!(path)) == @passed
    assert Result.write(nil, @passed) == :ok
  end

  @tag :tmp_dir
  test "a file it cannot write is reported, not raised", %{tmp_dir: dir} do
    path = Path.join([dir, "missing", "result.json"])

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        send(self(), {:written, Result.write(path, @passed)})
      end)

    assert_received {:written, {:error, :enoent}}
    assert output =~ "Could not write the result file"
  end
end
