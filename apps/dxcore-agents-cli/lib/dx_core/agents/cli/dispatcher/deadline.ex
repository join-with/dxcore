defmodule DxCore.Agents.CLI.Dispatcher.Deadline do
  @moduledoc """
  `dxcore dispatch --deadline <time>`. The dispatcher hands the deadline (and
  the hard stop, `--hard-stop-after` seconds later) to the coordinator, which
  owns the run's clock and verdict (#15513). The exit code follows the verdict:
  0 passed, 75 (EX_TEMPFAIL) unfinished, 1 failed. A rerun dispatches only
  what is left, since turbo cached every task that finished.
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

  @doc """
  Milliseconds from `now` to the dispatcher's first read of the run's verdict:
  `grace_ms` after the coordinator's hard stop, which ends every deadline run.
  """
  @spec verdict_backstop_ms(DateTime.t(), non_neg_integer(), non_neg_integer(), DateTime.t()) ::
          non_neg_integer()
  def verdict_backstop_ms(%DateTime{} = deadline, hard_stop_after_ms, grace_ms, %DateTime{} = now) do
    max(DateTime.diff(deadline, now, :millisecond) + hard_stop_after_ms + grace_ms, 0)
  end

  @doc "The process exit code for the dispatcher's stop reason."
  @spec exit_code(term()) :: 0 | 1 | 75
  def exit_code(:normal), do: 0
  def exit_code({:shutdown, :unfinished}), do: @unfinished_exit
  def exit_code(_reason), do: 1
end
