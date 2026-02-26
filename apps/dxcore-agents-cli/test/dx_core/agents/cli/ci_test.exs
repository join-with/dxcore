defmodule DxCore.Agents.CLI.CiTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.CLI.Ci

  describe "parse_finish_args/1" do
    test "extracts all flags" do
      args = [
        "finish",
        "--coordinator",
        "http://100.1.2.3:4000",
        "--session-id",
        "ses_abc",
        "--token",
        "tdx_ci_xyz",
        "--dispatcher-result",
        "success"
      ]

      opts = Ci.parse_finish_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://100.1.2.3:4000"
      assert Keyword.fetch!(opts, :session_id) == "ses_abc"
      assert Keyword.fetch!(opts, :token) == "tdx_ci_xyz"
      assert Keyword.fetch!(opts, :dispatcher_result) == "success"
    end

    test "extracts with short aliases" do
      args = ["finish", "-c", "http://x:4000", "-s", "ses_1", "-t", "tok", "-d", "failure"]
      opts = Ci.parse_finish_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://x:4000"
      assert Keyword.fetch!(opts, :session_id) == "ses_1"
      assert Keyword.fetch!(opts, :token) == "tok"
      assert Keyword.fetch!(opts, :dispatcher_result) == "failure"
    end
  end

  describe "finish_result/2" do
    test "returns :ok when dispatcher succeeded" do
      assert Ci.finish_result("success", {200, ~s({"status":"finished"})}) == :ok
    end

    test "returns error when dispatcher failed" do
      assert {:error, msg} = Ci.finish_result("failure", {200, ~s({"status":"finished"})})
      assert msg =~ "Dispatcher failed"
    end

    test "returns error when finish API returns non-200" do
      assert {:error, msg} = Ci.finish_result("success", {404, ~s({"error":"not found"})})
      assert msg =~ "404"
    end

    test "returns error when finish API unreachable" do
      assert {:error, msg} = Ci.finish_result("success", {0, ""})
      assert msg =~ "unreachable"
    end
  end

  describe "parse_shutdown_args/1" do
    test "extracts all flags" do
      args = [
        "shutdown",
        "--coordinator",
        "http://turbo-dte-coord-123",
        "--token",
        "tdx_ci_xyz"
      ]

      opts = Ci.parse_shutdown_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://turbo-dte-coord-123"
      assert Keyword.fetch!(opts, :token) == "tdx_ci_xyz"
    end

    test "extracts with short aliases" do
      args = ["shutdown", "-c", "http://x", "-t", "tok"]
      opts = Ci.parse_shutdown_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://x"
      assert Keyword.fetch!(opts, :token) == "tok"
    end
  end

  describe "parse_wait_args/1" do
    test "extracts coordinator with defaults" do
      args = ["wait", "--coordinator", "http://coord"]
      opts = Ci.parse_wait_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://coord"
      assert Keyword.fetch!(opts, :timeout) == 300
      assert Keyword.fetch!(opts, :interval) == 5
    end

    test "overrides defaults" do
      args = ["wait", "--coordinator", "http://x", "--timeout", "60", "--interval", "2"]
      opts = Ci.parse_wait_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://x"
      assert Keyword.fetch!(opts, :timeout) == 60
      assert Keyword.fetch!(opts, :interval) == 2
    end

    test "extracts with short aliases" do
      args = ["wait", "-c", "http://x"]
      opts = Ci.parse_wait_args(args)
      assert Keyword.fetch!(opts, :coordinator) == "http://x"
    end
  end

  describe "parse_create_session_args/1" do
    test "extracts all flags" do
      args = [
        "create-session",
        "--coordinator",
        "http://turbo-dte-coord-123",
        "--token",
        "tdx_ci_xyz"
      ]

      opts = Ci.parse_create_session_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://turbo-dte-coord-123"
      assert Keyword.fetch!(opts, :token) == "tdx_ci_xyz"
    end

    test "extracts with short aliases" do
      args = ["create-session", "-c", "http://x", "-t", "tok"]
      opts = Ci.parse_create_session_args(args)

      assert Keyword.fetch!(opts, :coordinator) == "http://x"
      assert Keyword.fetch!(opts, :token) == "tok"
    end
  end

  describe "check_health/1" do
    test "returns {0, \"\"} for unreachable host" do
      assert {0, ""} = Ci.check_health("http://127.0.0.1:1")
    end
  end

  describe "create_session_result/1" do
    test "returns {:ok, session_id} for 201 response" do
      assert {:ok, "ses_abc"} =
               Ci.create_session_result({201, ~s({"session_id":"ses_abc"})})
    end

    test "returns error for non-2xx response" do
      assert {:error, msg} = Ci.create_session_result({403, ~s({"error":"forbidden"})})
      assert msg =~ "403"
    end

    test "returns error when coordinator unreachable" do
      assert {:error, msg} = Ci.create_session_result({0, ""})
      assert msg =~ "unreachable"
    end

    test "returns error for malformed JSON body" do
      assert {:error, msg} = Ci.create_session_result({201, "not json"})
      assert msg =~ "Unexpected response"
    end

    test "returns error when session_id key is missing" do
      assert {:error, msg} = Ci.create_session_result({201, ~s({"status":"ok"})})
      assert msg =~ "Unexpected response"
    end

    test "returns error when session_id is empty string" do
      assert {:error, _msg} = Ci.create_session_result({201, ~s({"session_id":""})})
    end

    test "returns error when session_id is null" do
      assert {:error, _msg} = Ci.create_session_result({201, ~s({"session_id":null})})
    end
  end

  describe "shutdown_result/1" do
    test "returns :ok for 200 response" do
      assert Ci.shutdown_result({200, ~s({"status":"shutting_down"})}) == :ok
    end

    test "returns error for non-200 response" do
      assert {:error, msg} = Ci.shutdown_result({500, "Internal Server Error"})
      assert msg =~ "500"
    end

    test "returns error when coordinator unreachable" do
      assert {:error, msg} = Ci.shutdown_result({0, ""})
      assert msg =~ "unreachable"
    end
  end
end
