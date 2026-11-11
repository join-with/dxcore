defmodule DxCore.Agents.CLI.Dispatcher.Result do
  @moduledoc """
  The coordinator's verdict on a run (#15513), from `run_complete`'s `result`
  or GET /api/sessions/:id/run. The dispatcher exits on it (passed 0,
  unfinished 75, failed 1) and writes it to `--result-file`.
  """

  @verdicts ~w(passed failed unfinished)
  @keys ~w(result total cached left failed failed_tasks)

  def parse(
        %{
          "result" => verdict,
          "total" => total,
          "cached" => cached,
          "left" => left,
          "failed" => failed,
          "failed_tasks" => names
        } = raw
      )
      when verdict in @verdicts and is_integer(total) and is_integer(cached) and
             is_integer(left) and is_integer(failed) and is_list(names),
      do: {:ok, Map.take(raw, @keys)}

  def parse(_), do: :error

  def stop_reason(%{"result" => "passed"}), do: :normal
  def stop_reason(%{"result" => "unfinished"}), do: {:shutdown, :unfinished}
  def stop_reason(%{"result" => "failed"}), do: {:shutdown, :failed}

  def left_line(%{"left" => left, "total" => total, "cached" => cached}),
    do: "#{left} of #{total - cached} tasks left"

  def write(nil, _result), do: :ok

  def write(path, result) do
    case File.write(path, Jason.encode!(result)) do
      :ok ->
        :ok

      {:error, reason} = error ->
        IO.puts(
          "[dispatcher] Could not write the result file #{path}: #{:file.format_error(reason)}"
        )

        error
    end
  end
end
