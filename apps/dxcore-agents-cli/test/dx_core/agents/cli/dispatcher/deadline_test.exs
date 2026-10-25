defmodule DxCore.Agents.CLI.Dispatcher.DeadlineTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.CLI.Dispatcher.Deadline

  describe "options/1" do
    test "no flags: no deadline, a 120-second hard stop" do
      assert Deadline.options([]) == {:ok, %{deadline: nil, hard_stop_after_ms: 120_000}}
    end

    test "an ISO 8601 deadline with an offset, and a hard stop in seconds" do
      assert Deadline.options(deadline: "2026-10-25T10:12:00+02:00", hard_stop_after: "30") ==
               {:ok, %{deadline: ~U[2026-10-25 08:12:00Z], hard_stop_after_ms: 30_000}}
    end

    test "a deadline without an offset is refused" do
      assert {:error, "--deadline must be an ISO 8601 time with a UTC offset" <> _} =
               Deadline.options(deadline: "2026-10-25T10:12:00")
    end

    test "a deadline that is not a time is refused" do
      assert {:error, "--deadline must be" <> _} = Deadline.options(deadline: "in 12 minutes")
    end

    test "a hard stop that is not whole seconds in 0..3600 is refused" do
      for bad <- ["-1", "3601", "2m", "1.5", ""] do
        assert {:error, "--hard-stop-after must be" <> _} =
                 Deadline.options(hard_stop_after: bad),
               "accepted #{inspect(bad)}"
      end
    end

    test "the hard stop's bounds are accepted" do
      assert {:ok, %{hard_stop_after_ms: 0}} = Deadline.options(hard_stop_after: "0")
      assert {:ok, %{hard_stop_after_ms: 3_600_000}} = Deadline.options(hard_stop_after: "3600")
    end
  end

  describe "delays/3" do
    test "a future deadline: both timers count from now" do
      assert Deadline.delays(~U[2026-10-25 10:12:00Z], 120_000, ~U[2026-10-25 10:00:00Z]) ==
               {720_000, 840_000}
    end

    test "a deadline already past: drain now, hard stop after the grace" do
      assert Deadline.delays(~U[2026-10-25 10:00:00Z], 120_000, ~U[2026-10-25 10:05:00Z]) ==
               {0, 120_000}
    end
  end

  describe "exit_code/1" do
    test "maps each way a dispatch ends" do
      assert Deadline.exit_code(:normal) == 0
      assert Deadline.exit_code({:shutdown, :unfinished}) == 75
      assert Deadline.exit_code({:shutdown, :failed}) == 1
      assert Deadline.exit_code({:shutdown, :timeout}) == 1
      assert Deadline.exit_code({:shutdown, :submit_failed}) == 1
      assert Deadline.exit_code(:killed) == 1
    end
  end

  describe "left_line/2" do
    test "counts what is left of the tasks to run" do
      assert Deadline.left_line(5, 2) == "3 of 5 tasks left"
      assert Deadline.left_line(5, 7) == "0 of 5 tasks left"
    end

    test "says so when the coordinator gave no total" do
      assert Deadline.left_line(nil, 2) == "2 tasks finished, the number left is unknown"
    end
  end
end
