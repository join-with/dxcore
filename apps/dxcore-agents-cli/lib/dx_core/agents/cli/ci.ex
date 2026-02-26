defmodule DxCore.Agents.CLI.Ci do
  @moduledoc """
  CI helper commands that replace inline bash scripting in GitHub Actions workflows.

  Subcommands:
    - `create-session` -- POST /api/sessions, print session ID to stdout
    - `finish`   -- POST /finish to coordinator, report result
    - `shutdown` -- POST /shutdown to coordinator, trigger graceful exit
    - `wait`     -- poll coordinator health endpoint until reachable
  """

  @default_req_opts [connect_options: [timeout: 5_000], receive_timeout: 10_000, retry: false]

  @doc "Parse args for the `finish` subcommand."
  def parse_finish_args(["finish" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest,
        strict: [
          coordinator: :string,
          session_id: :string,
          token: :string,
          dispatcher_result: :string
        ],
        aliases: [c: :coordinator, s: :session_id, t: :token, d: :dispatcher_result]
      )

    opts
  end

  @doc """
  Evaluate the result of a finish operation.
  Takes the dispatcher result string and the HTTP response tuple {status_code, body}.
  """
  @spec finish_result(binary(), {non_neg_integer(), binary()}) :: :ok | {:error, binary()}
  def finish_result(_dispatcher_result, {0, _body}) do
    {:error, "Coordinator unreachable"}
  end

  def finish_result(_dispatcher_result, {status, body}) when status < 200 or status >= 300 do
    {:error, "Finish API returned #{status}: #{body}"}
  end

  def finish_result("success", {_status, _body}), do: :ok

  def finish_result(dispatcher_result, {_status, _body}) do
    {:error, "Dispatcher failed (#{dispatcher_result})"}
  end

  @doc "Parse args for the `shutdown` subcommand."
  def parse_shutdown_args(["shutdown" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest,
        strict: [coordinator: :string, token: :string],
        aliases: [c: :coordinator, t: :token]
      )

    opts
  end

  @doc "Parse args for the `create-session` subcommand."
  def parse_create_session_args(["create-session" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest,
        strict: [coordinator: :string, token: :string],
        aliases: [c: :coordinator, t: :token]
      )

    opts
  end

  @doc "Parse args for the `wait` subcommand."
  def parse_wait_args(["wait" | rest]) do
    {opts, _rest, _invalid} =
      OptionParser.parse(rest,
        strict: [coordinator: :string, timeout: :integer, interval: :integer],
        aliases: [c: :coordinator]
      )

    opts
    |> Keyword.put_new(:timeout, 300)
    |> Keyword.put_new(:interval, 5)
  end

  @doc "Check coordinator health. Returns {http_status, body} or {0, \"\"} if unreachable."
  @spec check_health(binary()) :: {non_neg_integer(), binary()}
  def check_health(coordinator) do
    do_request(:get, url: "#{coordinator}/api/health")
  end

  @doc "Evaluate the result of a shutdown operation."
  @spec shutdown_result({non_neg_integer(), binary()}) :: :ok | {:error, binary()}
  def shutdown_result({0, _body}), do: {:error, "Coordinator unreachable"}

  def shutdown_result({status, body}) when status < 200 or status >= 300 do
    {:error, "Shutdown API returned #{status}: #{body}"}
  end

  def shutdown_result({_status, _body}), do: :ok

  @doc "Evaluate the result of a create-session operation."
  @spec create_session_result({non_neg_integer(), binary()}) ::
          {:ok, binary()} | {:error, binary()}
  def create_session_result({0, _body}), do: {:error, "Coordinator unreachable"}

  def create_session_result({status, body}) when status < 200 or status >= 300 do
    {:error, "Create session API returned #{status}: #{body}"}
  end

  def create_session_result({_status, body}) do
    case Jason.decode(body) do
      {:ok, %{"session_id" => id}} when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, "Unexpected response: #{body}"}
    end
  end

  # ── Runner functions (side-effectful, called from CLI.main) ──────────

  @doc false
  def run(["finish" | _] = args) do
    opts = parse_finish_args(args)
    coordinator = Keyword.fetch!(opts, :coordinator)
    session_id = Keyword.fetch!(opts, :session_id)
    token = Keyword.fetch!(opts, :token)
    dispatcher_result = Keyword.get(opts, :dispatcher_result, "success")

    IO.puts("Finishing session #{session_id}...")
    response = post_finish(coordinator, session_id, token)

    case finish_result(dispatcher_result, response) do
      :ok ->
        {_status, body} = response
        IO.puts("Session finished: #{body}")

      {:error, msg} ->
        IO.puts("Error: #{msg}")
        System.halt(1)
    end
  end

  def run(["wait" | _] = args) do
    opts = parse_wait_args(args)
    coordinator = Keyword.fetch!(opts, :coordinator)
    timeout = Keyword.fetch!(opts, :timeout)
    interval = Keyword.fetch!(opts, :interval)

    IO.puts("Waiting for coordinator at #{coordinator}...")
    deadline = System.monotonic_time(:second) + timeout

    wait_loop(coordinator, interval, deadline, 1)
  end

  def run(["shutdown" | _] = args) do
    opts = parse_shutdown_args(args)
    coordinator = Keyword.fetch!(opts, :coordinator)
    token = Keyword.fetch!(opts, :token)

    IO.puts("Shutting down coordinator...")
    response = post_shutdown(coordinator, token)

    case shutdown_result(response) do
      :ok ->
        IO.puts("Coordinator shutting down")

      {:error, msg} ->
        IO.puts("Error: #{msg}")
        System.halt(1)
    end
  end

  def run(["create-session" | _] = args) do
    opts = parse_create_session_args(args)
    coordinator = Keyword.fetch!(opts, :coordinator)
    token = Keyword.fetch!(opts, :token)

    response = post_create_session(coordinator, token)

    case create_session_result(response) do
      {:ok, session_id} ->
        IO.puts(session_id)

      {:error, msg} ->
        IO.puts(:stderr, "Error: #{msg}")
        System.halt(1)
    end
  end

  def run(_) do
    IO.puts("Usage: dxcore-agents ci <create-session|finish|shutdown|wait> [options]")
    System.halt(1)
  end

  defp wait_loop(coordinator, interval, deadline, attempt) do
    if System.monotonic_time(:second) >= deadline do
      IO.puts("Failed to reach coordinator after #{attempt - 1} attempts")
      System.halt(1)
    end

    case check_health(coordinator) do
      {status, _} when status >= 200 and status < 300 ->
        IO.puts("Coordinator reachable (attempt #{attempt})")

      _ ->
        IO.puts("Attempt #{attempt}: waiting for coordinator...")
        Process.sleep(interval * 1_000)
        wait_loop(coordinator, interval, deadline, attempt + 1)
    end
  end

  defp post_finish(coordinator, session_id, token) do
    do_request(:post,
      url: "#{coordinator}/api/sessions/#{session_id}/finish",
      headers: [{"authorization", "Bearer #{token}"}]
    )
  end

  defp post_shutdown(coordinator, token) do
    do_request(:post,
      url: "#{coordinator}/api/shutdown",
      headers: [{"authorization", "Bearer #{token}"}]
    )
  end

  defp post_create_session(coordinator, token) do
    do_request(:post,
      url: "#{coordinator}/api/sessions",
      headers: [{"authorization", "Bearer #{token}"}]
    )
  end

  defp do_request(method, opts) do
    opts = Keyword.merge(@default_req_opts, opts)

    case apply(Req, method, [opts]) do
      {:ok, resp} ->
        body = if is_binary(resp.body), do: resp.body, else: Jason.encode!(resp.body)
        {resp.status, body}

      {:error, _} ->
        {0, ""}
    end
  end
end
