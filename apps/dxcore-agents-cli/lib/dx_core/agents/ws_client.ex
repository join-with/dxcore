defmodule DxCore.Agents.WsClient do
  @moduledoc """
  WebSocket client for connecting to the Phoenix coordinator.

  Wraps Slipstream to provide a simple API that forwards channel
  messages to a caller process. Handles connection, joining a topic,
  pushing messages, and automatic reconnection with a configurable
  timeout deadline.

  When the connection drops, the client uses exponential backoff
  (100ms, 500ms, 1s, 2s, 5s) and gives up after the reconnect
  timeout (default 30 seconds), stopping with `{:shutdown, :reconnect_timeout}`.

  ## Options

    * `:url` - WebSocket URL (required)
    * `:topic` - Phoenix channel topic to join (required)
    * `:caller` - PID to receive channel messages (required)
    * `:token` - authentication token (optional)
    * `:reconnect_timeout_ms` - max time in ms to keep retrying (default 30_000)

  ## Usage

      {:ok, client} = WsClient.start_link(
        url: "ws://localhost:4000/agent/websocket",
        topic: "agent:lobby",
        caller: self(),
        reconnect_timeout_ms: 30_000
      )

      # Caller receives:
      #   {:joined, topic}
      #   {:channel_message, topic, event, payload}
      #   {:join_error, topic, reason}
      #   {:disconnected, reason}

      WsClient.push(client, "agent_ready", %{"agent_id" => "agent-1"})
  """

  use Slipstream

  require Logger

  @reconnect_after_msec [100, 500, 1_000, 2_000, 5_000]

  # --- Public API ---

  @doc "Start the WebSocket client and connect to the coordinator."
  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)
    topic = Keyword.fetch!(opts, :topic)
    caller = Keyword.fetch!(opts, :caller)
    token = Keyword.get(opts, :token)
    reconnect_timeout_ms = Keyword.get(opts, :reconnect_timeout_ms, 30_000)

    config = %{
      url: url,
      topic: topic,
      caller: caller,
      token: token,
      reconnect_timeout_ms: reconnect_timeout_ms
    }

    Slipstream.start_link(__MODULE__, config)
  end

  @doc "Push an event with a payload to the joined channel."
  def push(client, event, payload) do
    GenServer.cast(client, {:push, event, payload})
  end

  @doc "Push an event and wait for the server reply (synchronous)."
  def push_and_wait(client, event, payload, timeout \\ 30_000) do
    GenServer.call(client, {:push_and_wait, event, payload}, timeout)
  end

  # --- Slipstream Callbacks ---

  @impl Slipstream
  def init(config) do
    socket =
      new_socket()
      |> assign(:topic, config.topic)
      |> assign(:caller, config.caller)
      |> assign(:pending_replies, %{})
      |> assign(:reconnect_timeout_ms, config.reconnect_timeout_ms)
      |> assign(:reconnect_deadline, nil)

    uri = append_token_param(config.url, config.token)
    {:ok, connect!(socket, uri: uri, reconnect_after_msec: @reconnect_after_msec)}
  end

  @impl Slipstream
  def handle_connect(socket) do
    topic = socket.assigns.topic
    Logger.info("[ws_client] Connected, joining #{topic}")
    {:ok, join(assign(socket, :reconnect_deadline, nil), topic)}
  end

  @impl Slipstream
  def handle_join(topic, _response, socket) do
    Logger.info("[ws_client] Joined #{topic}")
    send(socket.assigns.caller, {:joined, topic})
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(topic, event, payload, socket) do
    send(socket.assigns.caller, {:channel_message, topic, event, payload})
    {:ok, socket}
  end

  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    case Map.pop(socket.assigns.pending_replies, ref) do
      {nil, _pending} ->
        # Not a tracked reply, ignore
        {:ok, socket}

      {from, pending} ->
        GenServer.reply(from, reply)
        {:ok, assign(socket, :pending_replies, pending)}
    end
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("[ws_client] Disconnected: #{inspect(reason)}, attempting reconnect...")
    send(socket.assigns.caller, {:disconnected, reason})

    now = System.monotonic_time(:millisecond)
    deadline = socket.assigns.reconnect_deadline || now + socket.assigns.reconnect_timeout_ms
    socket = assign(socket, :reconnect_deadline, deadline)

    if now >= deadline do
      Logger.error(
        "[ws_client] Reconnect timeout exceeded " <>
          "(limit: #{socket.assigns.reconnect_timeout_ms}ms), giving up"
      )

      {:stop, {:shutdown, :reconnect_timeout}, socket}
    else
      reconnect(socket)
    end
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Logger.warning("[ws_client] Topic #{topic} closed: #{inspect(reason)}")
    send(socket.assigns.caller, {:topic_closed, topic, reason})
    {:ok, socket}
  end

  # --- GenServer handlers for push API ---

  @impl Slipstream
  def handle_call({:push_and_wait, event, payload}, from, socket) do
    topic = socket.assigns.topic
    {:ok, ref} = push(socket, topic, event, payload)

    pending = Map.put(socket.assigns.pending_replies, ref, from)
    {:noreply, assign(socket, :pending_replies, pending)}
  end

  @impl Slipstream
  def handle_cast({:push, event, payload}, socket) do
    topic = socket.assigns.topic

    case push(socket, topic, event, payload) do
      {:ok, _ref} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("[ws_client] Push failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  defp append_token_param(url, nil), do: url

  defp append_token_param(url, token) do
    uri = URI.parse(url)
    query = if uri.query, do: uri.query <> "&token=#{token}", else: "token=#{token}"
    URI.to_string(%{uri | query: query})
  end
end
