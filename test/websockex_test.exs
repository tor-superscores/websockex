defmodule WebSockexTest do
  use ExUnit.Case
  doctest WebSockex

  test "Set URI default ports for ws and wss" do
    assert URI.default_port("ws") == 80
    assert URI.default_port("wss") == 443
  end

  @basic_server_frame <<1::1, 0::3, 1::4, 0::1, 5::7, "Hello"::utf8>>

  defmodule TestClient do
    use WebSockex

    def start(url, state, opts \\ []) do
      WebSockex.start(url, __MODULE__, state, opts)
    end

    def start_link(url, state, opts \\ []) do
      WebSockex.start_link(url, __MODULE__, state, opts)
    end

    def catch_attr(client, atom), do: catch_attr(client, atom, self())
    def catch_attr(client, atom, receiver) do
      attr = "catch_" <> Atom.to_string(atom)
      WebSockex.cast(client, {:set_attr, String.to_atom(attr), receiver})
    end

    def format_status(_opt, [_pdict, %{fail_status: true}]) do
      raise "Failed Status"
    end
    def format_status(_opt, [_pdict, %{non_list_status: true}]) do
      {:data, "Not a list!"}
    end
    def format_status(_opt, [_pdict, %{custom_status: true}]) do
      [{:data, [{"Lemon", :pies}]}]
    end

    def get_conn(pid) do
      WebSockex.cast(pid, {:send_conn, self()})

      receive do
        conn = %WebSockex.Conn{} -> conn
      after
        500 -> raise "Didn't receive a Conn"
      end
    end

    def handle_connect(_conn, %{connect_badreply: true}), do: :lemons
    def handle_connect(_conn, %{connect_error: true}), do: raise "Connect Error"
    def handle_connect(_conn, %{connect_exit: true}), do: exit "Connect Exit"
    def handle_connect(_conn, %{catch_connect: pid} = args) do
      send(pid, :caught_connect)
      {:ok, args}
    end
    def handle_connect(_conn, %{async_test: true}) do
      receive do
        {:continue_async, pid} ->
          send(pid, :async_test)
          exit "Async Test"
        after
          50 ->
            raise "Async Timeout"
      end
    end
    def handle_connect(conn, state) do
      {:ok, Map.put(state, :conn, conn)}
    end

    def handle_cast({:pid_reply, pid}, state) do
      send(pid, :cast)
      {:ok, state}
    end
    def handle_cast({:set_state, state}, _state), do: {:ok, state}
    def handle_cast({:set_attr, key, attr}, state), do: {:ok, Map.put(state, key, attr)}
    def handle_cast({:get_state, pid}, state) do
      send(pid, state)
      {:ok, state}
    end
    def handle_cast({:send, frame}, state), do: {:reply, frame, state}
    def handle_cast(:close, state), do: {:close, state}
    def handle_cast({:close, code, reason}, state), do: {:close, {code, reason}, state}
    def handle_cast(:delayed_close, state) do
      receive do
        {:tcp_closed, socket} ->
          send(self(), {:tcp_closed, socket})
          {:close, state}
      end
    end
    def handle_cast({:send_conn, pid}, %{conn: conn} = state) do
      send pid, conn
      {:ok, state}
    end
    def handle_cast(:test_reconnect, state) do
      {:close, {4985, "Testing Reconnect"}, state}
    end
    def handle_cast(:bad_frame, state) do
      {:reply, {:haha, "No"}, state}
    end
    def handle_cast(:bad_reply, _), do: :lemon_pie
    def handle_cast(:error, _), do: raise "Cast Error"
    def handle_cast(:exit, _), do: exit "Cast Exit"

    def handle_info({:send, frame}, state), do: {:reply, frame, state}
    def handle_info(:close, state), do: {:close, state}
    def handle_info({:close, code, reason}, state), do: {:close, {code, reason}, state}
    def handle_info({:pid_reply, pid}, state) do
      send(pid, :info)
      {:ok, state}
    end
    def handle_info(:bad_reply, _), do: :lemon_pie
    def handle_info(:error, _), do: raise "Info Error"
    def handle_info(:exit, _), do: exit "Info Exit"

    def handle_ping({:ping, "Bad Reply"}, _), do: :lemon_pie
    def handle_ping({:ping, "Error"}, _), do: raise "Ping Error"
    def handle_ping({:ping, "Exit"}, _), do: exit "Ping Exit"
    def handle_ping(frame, state), do: super(frame, state)

    # Implicitly test default implementation defined with using through super
    def handle_pong(:pong = frame, %{catch_pong: pid} = state) do
      send(pid, :caught_pong)
      super(frame, state)
    end
    def handle_pong({:pong, msg} = frame, %{catch_pong: pid} = state) do
      send(pid, {:caught_payload_pong, msg})
      super(frame, state)
    end
    def handle_pong({:pong, "Bad Reply"}, _), do: :lemon_pie
    def handle_pong({:pong, "Error"}, _), do: raise "Pong Error"
    def handle_pong({:pong, "Exit"}, _), do: exit "Pong Exit"

    def handle_frame({:binary, msg}, %{catch_binary: pid} = state) do
      send(pid, {:caught_binary, msg})
      {:ok, state}
    end
    def handle_frame({:text, msg}, %{catch_text: pid} = state) do
      send(pid, {:caught_text, msg})
      {:ok, state}
    end
    def handle_frame({:text, "Bad Reply"}, _), do: :lemon_pie
    def handle_frame({:text, "Error"}, _), do: raise "Frame Error"
    def handle_frame({:text, "Exit"}, _), do: exit "Frame Exit"

    def handle_disconnect(_, %{disconnect_badreply: true}), do: :lemons
    def handle_disconnect(_, %{disconnect_error: true}), do: raise "Disconnect Error"
    def handle_disconnect(_, %{disconnect_exit: true}), do: exit "Disconnect Exit"
    def handle_disconnect(_, %{catch_init_connect_failure: pid} = state) do
      send(pid, :caught_initial_conn_failure)
      {:ok, state}
    end
    def handle_disconnect(%{attempt_number: 3} = failure_map, %{multiple_reconnect: pid} = state) do
      send(pid, {:stopping_retry, failure_map})
      {:ok, state}
    end
    def handle_disconnect(%{attempt_number: attempt} = failure_map, %{multiple_reconnect: pid} = state) do
      send(pid, {:retry_connect, failure_map})
      send(pid, {:check_retry_state, %{attempt: attempt, state: state}})
      {:reconnect, Map.put(state, :attempt, attempt)}
    end
    def handle_disconnect(_, %{change_conn_reconnect: pid, good_url: url} = state) do
      uri = URI.parse(url)
      conn = WebSockex.Conn.new(uri)
      send(pid, :retry_change_conn)
      {:reconnect, conn, state}
    end
    def handle_disconnect(%{reason: {:local, 4985, _}}, state) do
      {:reconnect, state}
    end
    def handle_disconnect(%{reason: {:remote, :closed}}, %{catch_disconnect: pid, reconnect: true} = state) do
    send(pid, {:caught_disconnect, :reconnecting})
    {:reconnect, state}
    end
    def handle_disconnect(_, %{reconnect: true} = state) do
      {:reconnect, state}
    end
    def handle_disconnect(%{reason: {:remote, :closed} = reason} = map,
                          %{catch_disconnect: pid} = state) do
      send(pid, {:caught_disconnect, reason})
      super(map, state)
    end
    def handle_disconnect(%{reason: {_, :normal}} = map,
                          %{catch_disconnect: pid} = state) do
      send(pid, :caught_disconnect)
      super(map, state)
    end
    def handle_disconnect(%{reason: {_, code, reason}}, %{catch_disconnect: pid} = state) do
      send(pid, {:caught_disconnect, code, reason})
      {:ok, state}
    end
    def handle_disconnect(_, %{catch_disconnect: pid} = state) do
      send(pid, :caught_disconnect)
      {:ok, state}
    end
    def handle_disconnect(_, state), do: {:ok, state}

    def terminate({:local, :normal}, %{catch_terminate: pid}), do: send(pid, :normal_close_terminate)
    def terminate(_, %{catch_terminate: pid}), do: send(pid, :terminate)
    def terminate(_, _), do: :ok
  end

  defmodule BareClient do
    use WebSockex
  end

  setup do
    {:ok, {server_ref, url}} = WebSockex.TestServer.start(self())

    on_exit fn -> WebSockex.TestServer.shutdown(server_ref) end

    {:ok, pid} = TestClient.start_link(url, %{})
    server_pid = WebSockex.TestServer.receive_socket_pid

    [pid: pid, url: url, server_pid: server_pid, server_ref: server_ref]
  end

  describe "start" do
    test "with a Conn struct", context do
      conn = WebSockex.Conn.new(URI.parse(context.url))

      assert {:ok, _} = WebSockex.start(conn, TestClient, %{catch_text: self()})
      server_pid = WebSockex.TestServer.receive_socket_pid()

      send(server_pid, {:send, {:text, "Start Link Conn"}})
      assert_receive {:caught_text, "Start Link Conn"}
    end

    test "with async option failure", context do
      assert {:ok, pid} =
        TestClient.start(context.url, %{async_test: true}, async: true)

      Process.monitor(pid)

      send(pid, {:continue_async, self()})

      assert_receive :async_test, 500
      assert_receive {:DOWN, _, :process, ^pid, "Async Test"}
    end

    test "without async option", context do
      Process.flag(:trap_exit, true)
      assert TestClient.start(context.url, %{async_test: true}) ==
        {:error, %RuntimeError{message: "Async Timeout"}}
    end

    test "returns an error with a bad url" do
      assert TestClient.start_link("lemon_pie", :ok) ==
        {:error, %WebSockex.URLError{url: "lemon_pie"}}
    end
  end

  describe "start_link" do
    test "with a Conn struct", context do
      conn = WebSockex.Conn.new(URI.parse(context.url))

      assert {:ok, _} = WebSockex.start_link(conn, TestClient, %{catch_text: self()})
      server_pid = WebSockex.TestServer.receive_socket_pid()

      send(server_pid, {:send, {:text, "Start Link Conn"}})
      assert_receive {:caught_text, "Start Link Conn"}
    end

    test "with async option", context do
      assert {:ok, _} =
        TestClient.start_link(context.url, %{catch_text: self()}, async: true)

      server_pid = WebSockex.TestServer.receive_socket_pid()

      send server_pid, {:send, {:text, "Hello"}}
      assert_receive {:caught_text, "Hello"}
    end

    test "without async option", context do
      Process.flag(:trap_exit, true)
      assert TestClient.start_link(context.url, %{async_test: true}) ==
        {:error, %RuntimeError{message: "Async Timeout"}}
    end

    test "with async option failure", context do
      Process.flag(:trap_exit, true)
      assert {:ok, pid} =
        TestClient.start_link(context.url, %{async_test: true}, async: true)

      send(pid, {:continue_async, self()})

      assert_receive :async_test, 500
      assert_receive {:EXIT, ^pid, "Async Test"}
    end

    test "returns an error with a bad url" do
      assert TestClient.start_link("lemon_pie", :ok) ==
        {:error, %WebSockex.URLError{url: "lemon_pie"}}
    end
  end

  test "can connect to secure server" do
    {:ok, {server_ref, url}} = WebSockex.TestServer.start_https(self())

    on_exit fn -> WebSockex.TestServer.shutdown(server_ref) end

    {:ok, pid} = TestClient.start_link(url, %{}, cacerts: WebSockex.TestServer.cacerts)
    server_pid = WebSockex.TestServer.receive_socket_pid

    TestClient.catch_attr(pid, :pong, self())

    # Test server -> client ping
    send server_pid, :send_ping
    assert_receive :received_pong

    # Test client -> server ping
    WebSockex.cast(pid, {:send, :ping})
    assert_receive :caught_pong
  end

  test "handles a tcp message send right after connecting", context do
    send(context.server_pid, :immediate_reply)

    assert {:ok, _pid} = TestClient.start_link(context.url, %{catch_text: self()})

    assert_receive {:caught_text, "Immediate Reply"}
  end

  test "handles a ssl message send right after connecting" do
    {:ok, {server_ref, url}} = WebSockex.TestServer.start_https(self())

    on_exit fn -> WebSockex.TestServer.shutdown(server_ref) end

    {:ok, _pid} = TestClient.start_link(url, %{})
    server_pid = WebSockex.TestServer.receive_socket_pid

    send(server_pid, :immediate_reply)

    assert {:ok, _pid} = TestClient.start_link(url, %{catch_text: self()})

    assert_receive {:caught_text, "Immediate Reply"}
  end

  test "handle changes state", context do
    rand_number = :rand.uniform(1000)

    WebSockex.cast(context.pid, {:get_state, self()})
    refute_receive ^rand_number

    WebSockex.cast(context.pid, {:set_state, rand_number})
    WebSockex.cast(context.pid, {:get_state, self()})
    assert_receive ^rand_number
  end

  test "can receive partial frames", context do
    WebSockex.cast(context.pid, {:send_conn, self()})
    TestClient.catch_attr(context.pid, :text, self())
    assert_receive conn = %WebSockex.Conn{}

    <<part::bits-size(14), rest::bits>> = @basic_server_frame

    send(context.pid, {conn.transport, conn.socket, part})
    send(context.pid, {conn.transport, conn.socket, rest})

    assert_receive {:caught_text, "Hello"}
  end

  test "can receive multiple frames", context do
    WebSockex.cast(context.pid, {:send_conn, self()})
    TestClient.catch_attr(context.pid, :text, self())
    assert_receive conn = %WebSockex.Conn{}
    :inet.setopts(conn.socket, active: false)

    send context.server_pid, {:send, {:text, "Hello"}}
    send context.server_pid, {:send, {:text, "Bye"}}

    :inet.setopts(conn.socket, active: true)

    assert_receive {:caught_text, "Hello"}
    assert_receive {:caught_text, "Bye"}
  end

  test "errors when receiving two fragment starts", context do
    Process.unlink(context.pid)
    WebSockex.cast(context.pid, {:send_conn, self()})
    assert_receive conn = %WebSockex.Conn{}
    fragment = <<0::1, 0::3, 1::4, 0::1, 2::7, "He"::utf8>>

    send(context.pid, {conn.transport, conn.socket, fragment})
    send(context.pid, {conn.transport, conn.socket, fragment})

    assert_receive {1002, "Endpoint tried to start a fragment without finishing another"}
  end

  test "errors with a continuation and no fragment", context do
    Process.unlink(context.pid)
    WebSockex.cast(context.pid, {:send_conn, self()})
    assert_receive conn = %WebSockex.Conn{}
    fragment = <<0::1, 0::3, 0::4, 0::1, 4::7, "Blah"::utf8>>

    send(context.pid, {conn.transport, conn.socket, fragment})

    assert_receive {1002, "Endpoint sent a continuation frame without starting a fragment"}
  end

  test "can receive text fragments", context do
    WebSockex.cast(context.pid, {:send_conn, self()})
    TestClient.catch_attr(context.pid, :text, self())
    assert_receive conn = %WebSockex.Conn{}

    first = <<0::1, 0::3, 1::4, 0::1, 2::7, "He"::utf8>>
    second = <<0::1, 0::3, 0::4, 0::1, 2::7, "ll"::utf8>>
    final = <<1::1, 0::3, 0::4, 0::1, 1::7, "o"::utf8>>

    send(context.pid, {conn.transport, conn.socket, first})
    send(context.pid, {conn.transport, conn.socket, second})
    send(context.pid, {conn.transport, conn.socket, final})

    assert_receive {:caught_text, "Hello"}
  end

  test "can receive binary fragments", context do
    WebSockex.cast(context.pid, {:send_conn, self()})
    TestClient.catch_attr(context.pid, :binary, self())
    assert_receive conn = %WebSockex.Conn{}
    binary = :erlang.term_to_binary(:hello)

    <<first_bin::bytes-size(2), second_bin::bytes-size(2), rest::bytes>> = binary
    len = byte_size(rest)

    first = <<0::1, 0::3, 2::4, 0::1, 2::7, first_bin::bytes>>
    second = <<0::1, 0::3, 0::4, 0::1, 2::7, second_bin::bytes>>
    final = <<1::1, 0::3, 0::4, 0::1, len::7, rest::bytes>>

    send(context.pid, {conn.transport, conn.socket, first})
    send(context.pid, {conn.transport, conn.socket, second})
    send(context.pid, {conn.transport, conn.socket, final})

    assert_receive {:caught_binary, ^binary}
  end

  test "send_frame", context do
    TestClient.catch_attr(context.pid, :pong, self())
    assert WebSockex.send_frame(context.pid, :ping) == :ok

    assert_receive :caught_pong
  end

  test "send_frame with error", context do
    Process.flag(:trap_exit, true)

    TestClient.catch_attr(context.pid, :disconnect)

    conn = TestClient.get_conn(context.pid)
    # Really glad that I got those sys behaviors now
    :sys.suspend(context.pid)

    WebSockex.send_frame(context.pid, {:text, "hello"})
    :gen_tcp.shutdown(conn.socket, :write)

    :sys.resume(context.pid)

    assert_receive :caught_disconnect
    assert_receive {:EXIT, _, %WebSockex.ConnError{original: :closed}}
  end

  describe "handle_cast callback" do
    test "is called", context do
      WebSockex.cast(context.pid, {:pid_reply, self()})

      assert_receive :cast
    end

    test "can reply with a message", context do
      message = :erlang.term_to_binary(:cast_msg)
      WebSockex.cast(context.pid, {:send, {:binary, message}})

      assert_receive :cast_msg
    end

    test "can close the connection", context do
      WebSockex.cast(context.pid, :close)

      assert_receive :normal_remote_closed
    end

    test "can close the connection with a code and a message", context do
      Process.flag(:trap_exit, true)
      WebSockex.cast(context.pid, {:close, 4012, "Test Close"})

      assert_receive {:EXIT, _, {:local, 4012, "Test Close"}}
      assert_receive {4012, "Test Close"}
    end

    test "handles errors while replying properly", context do
      Process.flag(:trap_exit, true)
      TestClient.catch_attr(context.pid, :disconnect, self())
      WebSockex.cast(context.pid, :bad_frame)

      assert_receive {1011, ""}
      assert_receive {:EXIT, _, %WebSockex.InvalidFrameError{}}
    end
  end

  describe "handle_connect callback" do
    test "gets invoked after successful connection", context do
      {:ok, _pid} = TestClient.start_link(context.url, %{catch_connect: self()})

      assert_receive :caught_connect
    end

    test "gets invoked after reconnection", context do
      TestClient.catch_attr(context.pid, :connect, self())
      WebSockex.cast(context.pid, {:set_attr, :reconnect, true})

      send(context.server_pid, :close)

      assert_receive :caught_connect
    end
  end

  describe "handle_frame" do
    test "can handle a binary frame", context do
      TestClient.catch_attr(context.pid, :binary, self())
      binary = :erlang.term_to_binary(:hello)
      send(context.server_pid, {:send, {:binary, binary}})

      assert_receive {:caught_binary, ^binary}
    end

    test "can handle a text frame", context do
      TestClient.catch_attr(context.pid, :text, self())
      text = "Murky is green"
      send(context.server_pid, {:send, {:text, text}})

      assert_receive {:caught_text, ^text}
    end
  end

  describe "handle_info callback" do
    test "is called", context do
      send(context.pid, {:pid_reply, self()})

      assert_receive :info
    end

    test "can reply with a message", context do
      message = :erlang.term_to_binary(:info_msg)
      send(context.pid, {:send, {:binary, message}})

      assert_receive :info_msg
    end

    test "can close the connection normally", context do
      send(context.pid, :close)

      assert_receive :normal_remote_closed
    end

    test "can close the connection with a code and a message", context do
      Process.flag(:trap_exit, true)
      send(context.pid, {:close, 4012, "Test Close"})

      assert_receive {:EXIT, _, {:local, 4012, "Test Close"}}
      assert_receive {4012, "Test Close"}
    end
  end

  describe "terminate callback" do
    setup context do
      TestClient.catch_attr(context.pid, :terminate, self())
    end

    test "executes in a handle_info bad reply", %{pid: pid} do
      Process.flag(:trap_exit, true)
      send(pid, :bad_reply)

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, %WebSockex.BadResponseError{}}
      assert_received :terminate
    end

    test "executes in a handle_info error", %{pid: pid} do
      Process.flag(:trap_exit, true)
      send(pid, :error)

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, {%RuntimeError{message: "Info Error"}, _}}
      assert_received :terminate
    end

    test "executes in a handle_info exit", %{pid: pid} do
      Process.flag(:trap_exit, true)
      send(pid, :exit)

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, "Info Exit"}
      assert_received :terminate
    end

    test "executes in handle_cast bad reply", %{pid: pid} do
      Process.flag(:trap_exit, true)
      WebSockex.cast(pid, :bad_reply)

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, %WebSockex.BadResponseError{}}
      assert_received :terminate
    end

    test "executes in handle_cast error", %{pid: pid} do
      Process.flag(:trap_exit, true)
      WebSockex.cast(pid, :error)

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, {%RuntimeError{message: "Cast Error"}, _}}
      assert_received :terminate
    end

    test "executes in handle_cast exit", %{pid: pid} do
      Process.flag(:trap_exit, true)
      WebSockex.cast(pid, :exit)

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, "Cast Exit"}
      assert_received :terminate
    end

    test "executes in handle_frame bad reply", %{pid: pid} = context do
      Process.flag(:trap_exit, true)
      send context.server_pid, {:send, {:text, "Bad Reply"}}

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, %WebSockex.BadResponseError{}}
      assert_received :terminate
    end

    test "executes in handle_frame error", %{pid: pid} = context do
      Process.flag(:trap_exit, true)
      send context.server_pid, {:send, {:text, "Error"}}

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, {%RuntimeError{message: "Frame Error"}, _}}
      assert_received :terminate
    end

    test "executes in handle_frame exit", %{pid: pid} = context do
      Process.flag(:trap_exit, true)
      send context.server_pid, {:send, {:text, "Exit"}}

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, "Frame Exit"}
      assert_received :terminate
    end

    test "executes in handle_ping bad reply", %{pid: pid} = context do
      Process.flag(:trap_exit, true)
      send context.server_pid, {:send, {:ping, "Bad Reply"}}

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, %WebSockex.BadResponseError{}}, 500
      assert_received :terminate
    end

    test "executes in handle_ping error", %{pid: pid} = context do
      Process.flag(:trap_exit, true)
      send context.server_pid, {:send, {:ping, "Error"}}

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, {%RuntimeError{message: "Ping Error"}, _}}
      assert_received :terminate
    end

    test "executes in handle_ping exit", %{pid: pid} = context do
      Process.flag(:trap_exit, true)
      send context.server_pid, {:send, {:ping, "Exit"}}

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, "Ping Exit"}
      assert_received :terminate
    end

    test "executes in handle_pong bad reply", %{pid: pid} = context do
      Process.flag(:trap_exit, true)
      send context.server_pid, {:send, {:pong, "Bad Reply"}}

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, %WebSockex.BadResponseError{}}
      assert_received :terminate
    end

    test "executes in handle_pong error", %{pid: pid} = context do
      Process.flag(:trap_exit, true)
      send context.server_pid, {:send, {:pong, "Error"}}

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, {%RuntimeError{message: "Pong Error"}, _}}
      assert_received :terminate
    end

    test "executes in handle_pong exit", %{pid: pid} = context do
      Process.flag(:trap_exit, true)
      send context.server_pid, {:send, {:pong, "Exit"}}

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, "Pong Exit"}
      assert_received :terminate
    end

    test "executes in handle_disconnect bad reply", %{pid: pid} do
      Process.flag(:trap_exit, true)
      WebSockex.cast(pid, {:set_attr, :disconnect_badreply, true})

      WebSockex.cast(pid, :close)

      assert_receive {:EXIT, ^pid, %WebSockex.BadResponseError{}}
      assert_received :terminate
    end

    test "executes in handle_disconnect error", %{pid: pid} do
      Process.flag(:trap_exit, true)
      WebSockex.cast(pid, {:set_attr, :disconnect_error, true})

      WebSockex.cast(pid, :close)

      assert_receive {:EXIT, ^pid, {%RuntimeError{message: "Disconnect Error"}, _}}
      assert_received :terminate
    end

    test "executes in handle_disconnect exit", %{pid: pid} do
      Process.flag(:trap_exit, true)
      WebSockex.cast(pid, {:set_attr, :disconnect_exit, true})

      WebSockex.cast(pid, :close)

      assert_receive {:EXIT, ^pid, "Disconnect Exit"}
      assert_received :terminate
    end

    test "is not executed in handle_disconnect before initialized", context do
      assert {:error, %WebSockex.BadResponseError{}} =
        TestClient.start_link(context.url <> "bad",
                              %{disconnect_badreply: true},
                              handle_initial_conn_failure: true)

      refute_received :terminate
    end

    test "executes in handle_connect bad reply", %{pid: pid} do
      Process.flag(:trap_exit, true)
      WebSockex.cast(pid, {:set_attr, :connect_badreply, true})
      WebSockex.cast(pid, {:set_attr, :reconnect, true})

      WebSockex.cast(pid, :close)

      assert_receive {:EXIT, ^pid, %WebSockex.BadResponseError{}}
      assert_received :terminate
    end

    test "executes in handle_connect error", %{pid: pid} do
      Process.flag(:trap_exit, true)
      WebSockex.cast(pid, {:set_attr, :connect_badreply, true})
      WebSockex.cast(pid, {:set_attr, :reconnect, true})

      WebSockex.cast(pid, :close)

      assert_receive {:EXIT, ^pid, %WebSockex.BadResponseError{}}
      assert_received :terminate
    end

    test "executes in handle_connect exit", %{pid: pid} do
      Process.flag(:trap_exit, true)
      WebSockex.cast(pid, {:set_attr, :connect_badreply, true})
      WebSockex.cast(pid, {:set_attr, :reconnect, true})

      WebSockex.cast(pid, :close)

      assert_receive {:EXIT, ^pid, %WebSockex.BadResponseError{}}
      assert_received :terminate
    end

    test "is not executed in handle_connect before initialized", context do
      assert {:error, %WebSockex.BadResponseError{}} =
        TestClient.start_link(context.url,
                              %{connect_badreply: true},
                              handle_initial_conn_failure: true)

      refute_received :terminate
    end

    test "executes in a frame close", context do
      WebSockex.cast(context.pid, :close)

      assert_receive :normal_close_terminate
    end
  end

  describe "handle_ping callback" do
    test "can handle a ping frame", context do
      send(context.server_pid, :send_ping)

      assert_receive :received_pong
    end

    test "can handle a ping frame with a payload", context do
      send(context.server_pid, :send_payload_ping)

      assert_receive :received_payload_pong
    end
  end

  describe "handle_pong callback" do
    test "can handle a pong frame", context do
      TestClient.catch_attr(context.pid, :pong, self())
      WebSockex.cast(context.pid, {:send, :ping})

      assert_receive :caught_pong
    end

    test "can handle a pong frame with a payload", context do
      TestClient.catch_attr(context.pid, :pong, self())
      WebSockex.cast(context.pid, {:send, {:ping, "bananas"}})

      assert_receive {:caught_payload_pong, "bananas"}
    end
  end

  describe "disconnects and handle_disconnect callback" do
    setup context do
      Process.unlink(context.pid)
      Process.monitor(context.pid)
      TestClient.catch_attr(context.pid, :disconnect, self())
    end

    test "is invoked when receiving a close frame", context do
      send(context.server_pid, :close)

      assert_receive :caught_disconnect, 1250
    end

    test "is invoked when receiving a close frame with a payload", context do
      send(context.server_pid, {:close, 4025, "Testing"})

      assert_receive {:caught_disconnect, 4025, "Testing"}, 1250
    end

    test "is invoked when sending a close frame", context do
      WebSockex.cast(context.pid, :close)

      assert_receive :caught_disconnect, 1250
    end

    test "is invoked when sending a close frame with a payload", context do
      WebSockex.cast(context.pid, {:close, 4025, "Testing"})

      assert_receive {:caught_disconnect, 4025, "Testing"}, 1250
    end

    test "can reconnect to the endpoint", context do
      Process.link(context.pid)
      TestClient.catch_attr(context.pid, :text, self())
      WebSockex.cast(context.pid, :test_reconnect)

      assert_receive {4985, "Testing Reconnect"}

      server_pid = WebSockex.TestServer.receive_socket_pid
      send(server_pid, {:send, {:text, "Hello"}})

      assert_receive {:caught_text, "Hello"}, 500
    end

    test "can attempt to reconnect multiple times", %{pid: client_pid} = context do
      WebSockex.cast(client_pid, {:set_attr, :multiple_reconnect, self()})

      send(context.server_pid, {:set_code, 403})
      send(context.server_pid, :shutdown)

      assert_receive {:retry_connect, %{conn: %WebSockex.Conn{}, attempt_number: 1}}
      assert_receive {:check_retry_state, %{attempt: 1}}
      assert_receive {:retry_connect, %{conn: %WebSockex.Conn{}, reason: %{code: 403}, attempt_number: 2}}
      assert_receive {:check_retry_state, %{attempt: 2, state: %{attempt: 1}}}
      assert_receive {:stopping_retry, %{conn: %WebSockex.Conn{}, reason: %{code: 403}, attempt_number: 3}}
      assert_receive {:DOWN, _ref, :process, ^client_pid, %WebSockex.RequestError{code: 403}}
    end

    test "can provide new conn struct during reconnect", context do
      {:ok, {server_ref, new_url}} = WebSockex.TestServer.start(self())
      on_exit fn -> WebSockex.TestServer.shutdown(server_ref) end

      WebSockex.cast(context.pid, {:set_attr, :change_conn_reconnect, self()})
      WebSockex.cast(context.pid, {:set_attr, :good_url, new_url})
      TestClient.catch_attr(context.pid, :text, self())

      send(context.server_pid, {:set_code, 403})
      send(context.server_pid, :shutdown)

      server_pid = WebSockex.TestServer.receive_socket_pid()

      assert_received :retry_change_conn

      send(server_pid, {:send, {:text, "Hello"}})

      assert_receive {:caught_text, "Hello"}
    end

    test "can handle remote closures during client close initiation", context do
      WebSockex.cast(context.pid, :delayed_close)
      Process.exit(context.server_pid, :kill)

      assert_receive {:caught_disconnect, {:remote, :closed}}
    end

    test "can handle random remote closures", context do
      Process.exit(context.server_pid, :kill)

      assert_receive {:caught_disconnect, {:remote, :closed}}
    end

    test "reconnects reset buffer", context do
      <<part::bits-size(14), _::bits>> = @basic_server_frame

      WebSockex.cast(context.pid, {:send_conn, self()})
      TestClient.catch_attr(context.pid, :text, self())
      assert_receive conn = %WebSockex.Conn{}

      WebSockex.cast(context.pid, {:set_attr, :reconnect, true})

      Process.exit(context.server_pid, :kill)

      send(context.pid, {conn.transport, conn.socket, part})

      assert_receive {:caught_disconnect, :reconnecting}

      server_pid = WebSockex.TestServer.receive_socket_pid
      send(server_pid, {:send, {:text, "Hello"}})

      assert_receive {:caught_text, "Hello"}
    end

    test "local close timeout", context do
      send(context.server_pid, :stall)

      WebSockex.cast(context.pid, :close)

      send(context.pid, :"$websockex_close_timeout")

      assert_receive :caught_disconnect
    end

    test "gets invoked during initial connect with handle_initial_conn_failure", context do
      assert {:error, _} = TestClient.start_link(context.url <> "bad",
                                                 %{catch_init_connect_failure: self()},
                                                 handle_initial_conn_failure: true)

      assert_receive :caught_initial_conn_failure
    end

    test "doesn't get invoked during initial connect without retry", context do
      assert {:error, _} = TestClient.start_link(context.url <> "bad", %{catch_init_connect_failure: self()})

      refute_receive :caught_initial_conn_failure
    end

    test "can attempt to reconnect during an initial connect", context do
      assert {:error, _} = TestClient.start_link(context.url <> "bad",
                                                 %{multiple_reconnect: self()},
                                                 handle_initial_conn_failure: true)

      assert_received {:retry_connect, %{conn: %WebSockex.Conn{}, reason: %{code: 404}, attempt_number: 1}}
      assert_received {:check_retry_state, %{attempt: 1}}
      assert_received {:retry_connect, %{conn: %WebSockex.Conn{}, reason: %{code: 404}, attempt_number: 2}}
      assert_received {:check_retry_state, %{attempt: 2, state: %{attempt: 1}}}
      assert_received {:stopping_retry, %{conn: %WebSockex.Conn{}, reason: %{code: 404}, attempt_number: 3}}
    end

    test "can reconnect with a new conn struct during an initial connection retry", context do
      state_map = %{change_conn_reconnect: self(), good_url: context.url, catch_text: self()}
      assert {:ok, _} = TestClient.start_link(context.url <> "bad", state_map, handle_initial_conn_failure: true)
      server_pid = WebSockex.TestServer.receive_socket_pid()

      assert_received :retry_change_conn

      send(server_pid, {:send, {:text, "Hello"}})

      assert_receive {:caught_text, "Hello"}
    end
  end

  describe "format_status callback" do
    test "is optional", context do
      import ExUnit.CaptureLog
      assert function_exported?(BareClient, :format_status, 2) == false

      {:ok, pid} = WebSockex.start_link(context.url, BareClient, :test)

      refute capture_log(fn ->
        {{:data, data}, _} = elem(:sys.get_status(pid), 3)
                             |> List.last
                             |> List.keydelete(:data, 0)
                             |> List.keytake(:data, 0)

        assert [{"State", _}] = data
      end) =~ "There was an error while invoking #{__MODULE__}.TestClient.format_status/2"
    end

    test "is invoked when implemented", context do
      WebSockex.cast(context.pid, {:set_attr, :custom_status, true})

      {{:data, data}, _} = elem(:sys.get_status(context.pid), 3)
                           |> List.last
                           |> List.keydelete(:data, 0)
                           |> List.keytake(:data, 0)

      assert [{"Lemon", :pies}] = data
    end

    test "falls back to default on error or exit", context do
      import ExUnit.CaptureLog
      WebSockex.cast(context.pid, {:set_attr, :fail_status, true})

      assert capture_log(fn ->
        {{:data, data}, _} = elem(:sys.get_status(context.pid), 3)
                             |> List.last
                             |> List.keydelete(:data, 0)
                             |> List.keytake(:data, 0)

        assert [{"State", _}] = data
      end) =~ "There was an error while invoking #{__MODULE__}.TestClient.format_status/2"
    end

    test "wraps a non-list return", context do
      WebSockex.cast(context.pid, {:set_attr, :non_list_status, true})

      {{:data, data}, _} = elem(:sys.get_status(context.pid), 3)
                           |> List.last
                           |> List.keydelete(:data, 0)
                           |> List.keytake(:data, 0)

      assert data == "Not a list!"
    end
  end

  test "Won't exit on a request error", context do
    assert TestClient.start_link(context.url <> "blah", %{}) ==
      {:error, %WebSockex.RequestError{code: 404, message: "Not Found"}}
  end

  describe "default implementation errors" do
    setup context do
      {:ok, pid} = WebSockex.start_link(context.url, BareClient, %{})
      server_pid = WebSockex.TestServer.receive_socket_pid

      [pid: pid, server_pid: server_pid]
    end

    test "handle_frame", context do
      Process.flag(:trap_exit, true)
      frame = {:text, "Hello"}
      send(context.server_pid, {:send, frame})

      message = "No handle_frame/2 clause in #{__MODULE__}.BareClient provided for #{inspect frame}"
      assert_receive {:EXIT, _, {%RuntimeError{message: ^message}, _}}
    end

    test "handle_cast", context do
      Process.flag(:trap_exit, true)
      WebSockex.cast(context.pid, :test)

      message = "No handle_cast/2 clause in #{__MODULE__}.BareClient provided for :test"
      assert_receive {:EXIT, _, {%RuntimeError{message: ^message}, _}}
    end

    test "handle_info", context do
      import ExUnit.CaptureLog

      assert capture_log(fn ->
        send context.pid, :info
        Process.sleep(50)
      end) =~ "No handle_info/2 clause in #{__MODULE__}.BareClient provided for :info"
    end
  end

  ## OTP Stuffs (That I know how to test)

  describe "OTP Compliance" do
    test "requires the child to exit when receiving a parent exit signal", context do
      Process.flag(:trap_exit, true)
      {:ok, pid} = WebSockex.start_link(context.url, BareClient, [])

      send(pid, {:EXIT, self(), "OTP Compliance Test"})

      assert_receive {1011, ""}
      assert_receive {:EXIT, ^pid, "OTP Compliance Test"}
    end

    test "exits with a parent exit signal while connecting", %{pid: pid} = context do
      Process.flag(:trap_exit, true)

      WebSockex.cast(pid, {:set_attr, :reconnect, true})
      TestClient.catch_attr(pid, :terminate, self())
      send(context.server_pid, :connection_wait)
      send(context.server_pid, :close)

      _new_server_pid = WebSockex.TestServer.receive_socket_pid

      {:data, data} = elem(:sys.get_status(pid), 3)
                      |> List.flatten
                      |> List.keyfind(:data, 0)

      assert {"Connection Status", :connecting} in data

      send(pid, {:EXIT, self(), "OTP Compliance Test"})
      assert_receive {:EXIT, ^pid, "OTP Compliance Test"}
      assert_received :terminate
    end

    test "a parent exit signal doesn't call terminate on initial connect", context do
      Process.flag(:trap_exit, true)
      send(context.server_pid, :connection_wait)

      {:ok, pid} = TestClient.start_link(context.url,
                                         %{catch_terminate: self()},
                                         async: true)

      {:data, data} = elem(:sys.get_status(pid), 3)
                      |> List.flatten
                      |> List.keyfind(:data, 0)

      assert {"Connection Status", :connecting} in data

      send(pid, {:EXIT, self(), "OTP Compliance Test"})
      assert_receive {:EXIT, ^pid, "OTP Compliance Test"}
      refute_received :terminate
    end

    test "can send system messages while connecting", context do
      send(context.server_pid, :connection_wait)

      {:ok, pid} = WebSockex.start_link(context.url, BareClient, [], async: true)

      {:data, data} = elem(:sys.get_status(pid), 3)
                      |> List.flatten
                      |> List.keyfind(:data, 0)

      assert {"Connection Status", :connecting} in data

      new_server_pid = WebSockex.TestServer.receive_socket_pid()
      send(new_server_pid, :connection_continue)
      ^new_server_pid = WebSockex.TestServer.receive_socket_pid()

      send(new_server_pid, :send_ping)
      assert_receive :received_pong

      {:data, data} = elem(:sys.get_status(pid), 3)
                      |> List.flatten
                      |> List.keyfind(:data, 0)

      assert {"Connection Status", :connected} in data
    end

    test "can send system messages while closing", context do
      send(context.server_pid, :stall)
      TestClient.catch_attr(context.pid, :terminate, self())
      WebSockex.cast(context.pid, :close)

      {:data, data} = elem(:sys.get_status(context.pid), 3)
                      |> List.flatten
                      |> List.keyfind(:data, 0)

      assert {"Connection Status", {:closing, {:local, :normal}}} in data

      send(context.pid, :"$websockex_close_timeout")
    end

    test "exits with a parent exit signal while closing", %{pid: pid} = context do
      Process.flag(:trap_exit, true)
      TestClient.catch_attr(pid, :terminate, self())
      WebSockex.cast(context.pid, :close)

      send(context.server_pid, :stall)

      {:data, data} = elem(:sys.get_status(pid), 3)
                      |> List.flatten
                      |> List.keyfind(:data, 0)

      assert {"Connection Status", {:closing, {:local, :normal}}} in data

      send(pid, {:EXIT, self(), "OTP Compliance Test"})
      assert_receive {:EXIT, ^pid, "OTP Compliance Test"}
      assert_received :terminate
    end
  end

  test ":sys.replace_state only replaces module_state", context do
    :sys.replace_state(context.pid, fn(_) -> :lemon end)
    WebSockex.cast(context.pid, {:get_state, self()})

    assert_receive :lemon
  end

  test ":sys.get_state only returns module_state", context do
    get_state = :sys.get_state(context.pid)

    WebSockex.cast(context.pid, {:get_state, self()})

    assert_receive ^get_state
  end

  # Other `format_status` stuff in tested in callback section
  test ":sys.get_status returns from format_status", context do
    {{:data, data}, rest} = elem(:sys.get_status(context.pid), 3)
                            |> List.last
                            |> List.keytake(:data, 0)

    assert {"Connection Status", :connected} in data

    # A second data tuple means pretty output for `:observer`. Who knew?
    assert {:data, _data} = List.keyfind(rest, :data, 0)
  end
end
