defmodule DxCore.Agents.CLI.Dispatcher.RunReader do
  @moduledoc """
  Reads a session's latest run from the coordinator (GET /api/sessions/:id/run,
  #15513), for a dispatcher that missed `run_complete`.
  """

  @retry_after_ms 1_000

  @doc """
  One bounded retry after a second on a transport error or a 5xx; `get` and
  `sleep` are injectable for tests.
  """
  def fetch(
        coordinator_url,
        token,
        session_id,
        get \\ &Req.get/2,
        sleep \\ &Process.sleep/1
      ) do
    case fetch_once(coordinator_url, token, session_id, get) do
      {:error, reason} = error ->
        if retryable?(reason) do
          sleep.(@retry_after_ms)
          fetch_once(coordinator_url, token, session_id, get)
        else
          error
        end

      ok ->
        ok
    end
  end

  defp retryable?({:http, status}), do: status >= 500
  defp retryable?(:bad_body), do: false
  defp retryable?(_transport), do: true

  defp fetch_once(coordinator_url, token, session_id, get) do
    url =
      String.trim_trailing(coordinator_url, "/") <>
        "/api/sessions/" <> URI.encode(session_id, &URI.char_unreserved?/1) <> "/run"

    case get.(url, headers: [{"authorization", "Bearer " <> token}], retry: false) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %{status: 200}} -> {:error, :bad_body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
