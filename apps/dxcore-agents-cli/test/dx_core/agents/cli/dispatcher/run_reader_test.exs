defmodule DxCore.Agents.CLI.Dispatcher.RunReaderTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.CLI.Dispatcher.RunReader

  test "reads the session's run with the token" do
    me = self()

    get = fn url, opts ->
      send(me, {:get, url, opts[:headers]})
      {:ok, %{status: 200, body: %{"run" => %{"id" => "r1"}}}}
    end

    assert {:ok, %{"run" => %{"id" => "r1"}}} =
             RunReader.fetch("https://dxcore.dev/", "tok", "gha-1-2", get)

    assert_received {:get, "https://dxcore.dev/api/sessions/gha-1-2/run",
                     [{"authorization", "Bearer tok"}]}
  end

  test "a non-200 or a transport error is an error" do
    assert {:error, {:http, 404}} =
             RunReader.fetch("https://x", "t", "s", fn _, _ ->
               {:ok, %{status: 404, body: %{}}}
             end)

    assert {:error, :econnrefused} =
             RunReader.fetch("https://x", "t", "s", fn _, _ -> {:error, :econnrefused} end, & &1)
  end

  test "a transport error or a 5xx is retried once after a second" do
    me = self()
    sleep = fn ms -> send(me, {:slept, ms}) end

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    flaky = fn _, _ ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, :timeout}
        _ -> {:ok, %{status: 200, body: %{"run" => nil}}}
      end
    end

    assert {:ok, %{"run" => nil}} = RunReader.fetch("https://x", "t", "s", flaky, sleep)
    assert_received {:slept, 1000}

    assert {:error, {:http, 503}} =
             RunReader.fetch(
               "https://x",
               "t",
               "s",
               fn _, _ -> {:ok, %{status: 503, body: %{}}} end,
               sleep
             )

    assert_received {:slept, 1000}
    assert Agent.get(calls, & &1) == 2
  end

  test "a 4xx is not retried" do
    assert {:error, {:http, 404}} =
             RunReader.fetch(
               "https://x",
               "t",
               "s",
               fn _, _ -> {:ok, %{status: 404, body: %{}}} end,
               fn _ ->
                 flunk("retried a 404")
               end
             )
  end

  test "a 200 with no run passes through" do
    body = %{"session" => %{"id" => "s"}, "run" => nil}

    assert {:ok, ^body} =
             RunReader.fetch("https://x", "t", "s", fn _, _ ->
               {:ok, %{status: 200, body: body}}
             end)
  end

  test "a 200 whose body is not a map is a bad body" do
    assert {:error, :bad_body} =
             RunReader.fetch("https://x", "t", "s", fn _, _ ->
               {:ok, %{status: 200, body: "<html>"}}
             end)
  end

  test "does not retry, so an exiting dispatcher never waits on backoff" do
    me = self()

    get = fn _, opts ->
      send(me, {:opts, opts})
      {:ok, %{status: 200, body: %{}}}
    end

    RunReader.fetch("https://x", "t", "s", get)
    assert_received {:opts, opts}
    assert opts[:retry] == false
  end
end
