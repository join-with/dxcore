defmodule DxCore.Agents.CLI.Dispatcher.Deadline do
  @moduledoc """
  `dxcore dispatch --deadline <time>`. At the deadline the run hands out no
  new tasks (the coordinator's `drain_run`) and the running ones finish. Once
  nothing runs, or `--hard-stop-after` seconds after the deadline, the
  dispatcher cancels the rest and exits 75 (EX_TEMPFAIL): the run is
  unfinished, not failed. A rerun dispatches only what is left, since turbo
  cached every task that finished.
  """

  @unfinished_exit 75
  @default_hard_stop_after_s 120
  @max_hard_stop_after_s 3600

  @type options :: %{deadline: DateTime.t() | nil, hard_stop_after_ms: non_neg_integer()}

  @spec options(keyword()) :: {:ok, options()} | {:error, String.t()}
  def options(opts) do
    with {:ok, deadline} <- parse_deadline(Keyword.get(opts, :deadline)),
         {:ok, seconds} <- parse_hard_stop_after(Keyword.get(opts, :hard_stop_after)) do
      {:ok, %{deadline: deadline, hard_stop_after_ms: seconds * 1000}}
    end
  end

  defp parse_deadline(nil), do: {:ok, nil}

  defp parse_deadline(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, deadline, _offset} ->
        {:ok, deadline}

      {:error, _} ->
        {:error,
         "--deadline must be an ISO 8601 time with a UTC offset, " <>
           "e.g. 2026-10-25T10:12:00Z (got #{inspect(value)})"}
    end
  end

  defp parse_hard_stop_after(nil), do: {:ok, @default_hard_stop_after_s}

  defp parse_hard_stop_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds in 0..@max_hard_stop_after_s -> {:ok, seconds}
      _ -> hard_stop_error(value)
    end
  end

  defp hard_stop_error(value),
    do:
      {:error,
       "--hard-stop-after must be whole seconds from 0 to #{@max_hard_stop_after_s} " <>
         "(got #{inspect(value)})"}

  @doc "Milliseconds from `now` to the drain and to the hard stop."
  @spec delays(DateTime.t(), non_neg_integer(), DateTime.t()) ::
          {non_neg_integer(), non_neg_integer()}
  def delays(%DateTime{} = deadline, hard_stop_after_ms, %DateTime{} = now)
      when is_integer(hard_stop_after_ms) and hard_stop_after_ms >= 0 do
    until_deadline = max(DateTime.diff(deadline, now, :millisecond), 0)
    {until_deadline, until_deadline + hard_stop_after_ms}
  end

  @doc "The process exit code for the dispatcher's stop reason."
  @spec exit_code(term()) :: 0 | 1 | 75
  def exit_code(:normal), do: 0
  def exit_code({:shutdown, :unfinished}), do: @unfinished_exit
  def exit_code(_reason), do: 1

  @spec left_line(non_neg_integer() | nil, non_neg_integer()) :: String.t()
  def left_line(to_run, finished) when is_integer(to_run),
    do: "#{max(to_run - finished, 0)} of #{to_run} tasks left"

  def left_line(nil, finished), do: "#{finished} tasks finished, the number left is unknown"
end
