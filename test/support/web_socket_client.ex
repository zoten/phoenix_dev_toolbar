defmodule PhoenixDevToolbar.WebSocketClient do
  @moduledoc false
  # A minimal WebSocket client over :gen_tcp, for the panel socket's end to end
  # test (ADR 04): the upgrade handshake, masked text frames out, unmasked text
  # frames in. No dependency for one test.

  @spec connect(:inet.port_number(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, port()} | {:error, {integer(), String.t()}}
  def connect(port, path, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :raw])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    # A "Host" among the headers replaces the default one.
    {host, headers} =
      case Enum.split_with(headers, fn {name, _value} -> String.downcase(name) == "host" end) do
        {[{_name, host} | _], rest} -> {host, rest}
        {[], rest} -> {"localhost:#{port}", rest}
      end

    request =
      [
        "GET #{path} HTTP/1.1\r\n",
        "Host: #{host}\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Key: #{key}\r\n",
        "Sec-WebSocket-Version: 13\r\n",
        Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
        "\r\n"
      ]

    :ok = :gen_tcp.send(socket, request)
    {status, response} = read_head(socket, "")

    case status do
      101 -> {:ok, socket}
      other -> {:error, {other, response}}
    end
  end

  # Plain HTTP GET (no upgrade): the status code.
  @spec get_status(:inet.port_number(), String.t(), [{String.t(), String.t()}]) :: integer()
  def get_status(port, path, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false, packet: :raw])
    extra = Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end)

    :ok =
      :gen_tcp.send(socket, ["GET #{path} HTTP/1.1\r\nHost: localhost:#{port}\r\n", extra, "\r\n"])

    {status, _head} = read_head(socket, "")
    :gen_tcp.close(socket)
    status
  end

  @spec send_json(port(), term()) :: :ok
  def send_json(socket, term), do: send_frame(socket, Jason.encode!(term))

  # A raw frame: text (0x1) by default, or binary (0x2).
  @spec send_frame(port(), binary(), :text | :binary) :: :ok
  def send_frame(socket, payload, kind \\ :text) do
    opcode = %{text: 0x81, binary: 0x82} |> Map.fetch!(kind)
    mask = :crypto.strong_rand_bytes(4)

    :ok =
      :gen_tcp.send(socket, [opcode, length_header(byte_size(payload)), mask, mask(payload, mask)])
  end

  # Whether the server closed the connection (a close frame or the TCP close).
  @spec closed?(port(), timeout()) :: boolean()
  def closed?(socket, timeout \\ 2_000) do
    case :gen_tcp.recv(socket, 2, timeout) do
      {:ok, <<_fin::1, _rsv::3, 8::4, _rest::binary>>} -> true
      {:error, :closed} -> true
      _other -> false
    end
  end

  @spec recv_json(port(), timeout()) :: term()
  def recv_json(socket, timeout \\ 5_000) do
    {:ok, <<_fin_opcode, len>>} = :gen_tcp.recv(socket, 2, timeout)

    size =
      case len do
        126 -> recv_uint(socket, 2, timeout)
        127 -> recv_uint(socket, 8, timeout)
        size -> size
      end

    {:ok, payload} = :gen_tcp.recv(socket, size, timeout)
    Jason.decode!(payload)
  end

  defp recv_uint(socket, bytes, timeout) do
    {:ok, data} = :gen_tcp.recv(socket, bytes, timeout)
    :binary.decode_unsigned(data)
  end

  defp read_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, _rest] ->
        ["HTTP/1.1 " <> <<code::binary-size(3)>> <> _ | _] = String.split(head, "\r\n")
        {String.to_integer(code), head}

      [_partial] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_head(socket, acc <> data)
    end
  end

  defp length_header(size) when size < 126, do: <<1::1, size::7>>
  defp length_header(size) when size < 65_536, do: <<1::1, 126::7, size::16>>
  defp length_header(size), do: <<1::1, 127::7, size::64>>

  defp mask(payload, <<a, b, c, d>>) do
    keys = Stream.cycle([a, b, c, d])

    payload
    |> :binary.bin_to_list()
    |> Enum.zip(keys)
    |> Enum.map(fn {byte, key} -> Bitwise.bxor(byte, key) end)
    |> :binary.list_to_bin()
  end
end
