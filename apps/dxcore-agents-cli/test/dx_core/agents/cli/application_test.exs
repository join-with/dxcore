defmodule DxCore.Agents.CLI.ApplicationTest do
  use ExUnit.Case, async: true

  alias DxCore.Agents.CLI.Application

  describe "filter_ssl_alerts/2 with arity-1 report_cb" do
    test "wraps callback — original output preserved when callback succeeds" do
      original_cb = fn _data -> {"TLS alert: ~s", ["handshake failure"]} end

      event = %{
        level: :notice,
        msg: {:report, %{alert: :test, protocol: "TLS"}},
        meta: %{
          domain: [:otp, :ssl, :tls],
          report_cb: original_cb
        }
      }

      result = Application.filter_ssl_alerts(event, [])

      assert %{meta: %{report_cb: wrapped_cb}} = result
      assert is_function(wrapped_cb, 1)

      assert {"TLS alert: ~s", ["handshake failure"]} ==
               wrapped_cb.(%{alert: :test, protocol: "TLS"})
    end

    test "wraps callback — returns safe fallback when callback raises" do
      crashing_cb = fn _data -> raise "ssl_alert:own_alert_format undef" end

      event = %{
        level: :notice,
        msg: {:report, %{alert: :test}},
        meta: %{
          domain: [:otp, :ssl, :tls],
          report_cb: crashing_cb
        }
      }

      result = Application.filter_ssl_alerts(event, [])
      assert %{meta: %{report_cb: wrapped_cb}} = result

      {fmt, args} = wrapped_cb.(%{alert: :test})
      assert fmt == "SSL: ~p"
      assert args == [%{alert: :test}]
    end

    test "wraps callback — catches Erlang :undef errors (the real crash scenario)" do
      crashing_cb = fn _data -> :erlang.error(:undef) end

      event = %{
        level: :notice,
        msg: {:report, %{alert: :test}},
        meta: %{
          domain: [:otp, :ssl, :tls],
          report_cb: crashing_cb
        }
      }

      result = Application.filter_ssl_alerts(event, [])
      assert %{meta: %{report_cb: wrapped_cb}} = result

      {fmt, args} = wrapped_cb.(%{alert: :test})
      assert fmt == "SSL: ~p"
      assert args == [%{alert: :test}]
    end
  end

  describe "filter_ssl_alerts/2 with arity-2 report_cb" do
    test "wraps callback — returns safe fallback when callback raises" do
      crashing_cb = fn _data, _config -> raise "boom" end

      event = %{
        level: :notice,
        msg: {:report, %{alert: :test}},
        meta: %{
          domain: [:otp, :ssl, :tls],
          report_cb: crashing_cb
        }
      }

      result = Application.filter_ssl_alerts(event, [])
      assert %{meta: %{report_cb: wrapped_cb}} = result
      assert is_function(wrapped_cb, 2)

      output = wrapped_cb.(%{alert: :test}, %{})
      assert is_binary(output)
      assert output =~ "SSL: %{alert: :test}"
    end

    test "wraps callback — original output preserved when callback succeeds" do
      original_cb = fn _data, _config -> "TLS alert: handshake failure" end

      event = %{
        level: :notice,
        msg: {:report, %{alert: :test}},
        meta: %{
          domain: [:otp, :ssl, :tls],
          report_cb: original_cb
        }
      }

      result = Application.filter_ssl_alerts(event, [])
      assert %{meta: %{report_cb: wrapped_cb}} = result
      assert is_function(wrapped_cb, 2)
      assert wrapped_cb.(%{alert: :test}, %{}) == "TLS alert: handshake failure"
    end
  end

  describe "filter_ssl_alerts/2 passthrough" do
    test "returns event unchanged for non-SSL events" do
      event = %{
        level: :info,
        msg: {:string, "hello"},
        meta: %{domain: [:elixir]}
      }

      assert ^event = Application.filter_ssl_alerts(event, [])
    end

    test "returns event unchanged for SSL events without report_cb" do
      event = %{
        level: :notice,
        msg: {:string, "ssl connected"},
        meta: %{domain: [:otp, :ssl, :tls]}
      }

      assert ^event = Application.filter_ssl_alerts(event, [])
    end
  end
end
