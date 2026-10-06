defmodule Avwe.Test.WebSocketClient do
  @moduledoc """
  A websocket over a real socket, for end-to-end tests of the web client: an
  upgrade request the test writes itself, so that it can send any `Host` and
  `Origin`, and then text frames, which is all Phoenix's channels need.
  """

  import Bitwise

  alias Avwe.Test.HTTPClient

  @doc """
  Asks to upgrade `path` to a websocket, with `headers` (a cookie, an
  `Origin`, a `Host`). `{:error, status}` is the server's refusal.
  """
  @spec open(:inet.port_number(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, :gen_tcp.socket()} | {:error, pos_integer()}
  def open(port, path, headers) do
    upgrade = [
      {"upgrade", "websocket"},
      {"connection", "Upgrade"},
      {"sec-websocket-version", "13"},
      {"sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16))}
    ]

    case HTTPClient.open(port, "GET", path, upgrade ++ headers) do
      {socket, %{status: 101}} ->
        {:ok, socket}

      {socket, %{status: status}} ->
        :ok = :gen_tcp.close(socket)
        {:error, status}
    end
  end

  @doc "Sends a text frame, masked as a client's must be."
  @spec push(:gen_tcp.socket(), String.t()) :: :ok
  def push(socket, text) do
    mask = :crypto.strong_rand_bytes(4)
    :ok = :gen_tcp.send(socket, [header(byte_size(text)), mask, masked(text, mask)])
  end

  @doc "The next text frame, or `:closed` when the server closed the socket."
  @spec recv(:gen_tcp.socket(), timeout()) :: {:ok, String.t()} | :closed
  def recv(socket, timeout \\ 5_000) do
    with {:ok, <<_fin::1, _reserved::3, opcode::4, _mask::1, length::7>>} <-
           :gen_tcp.recv(socket, 2, timeout),
         {:ok, size} <- size(socket, length, timeout),
         {:ok, payload} <- payload(socket, size, timeout) do
      if opcode == 1, do: {:ok, payload}, else: :closed
    else
      {:error, :closed} -> :closed
    end
  end

  @doc "Closes the socket without a word, as a page that is gone does."
  @spec close(:gen_tcp.socket()) :: :ok
  def close(socket), do: :gen_tcp.close(socket)

  defp header(length) when length < 126, do: <<0x81, 0x80 ||| length>>
  defp header(length) when length < 65_536, do: <<0x81, 0x80 ||| 126, length::16>>
  defp header(length), do: <<0x81, 0x80 ||| 127, length::64>>

  defp masked(text, mask) do
    for <<byte <- text>>, reduce: {<<>>, 0} do
      {acc, index} -> {<<acc::binary, bxor(byte, :binary.at(mask, rem(index, 4)))>>, index + 1}
    end
    |> elem(0)
  end

  defp size(_socket, length, _timeout) when length < 126, do: {:ok, length}

  defp size(socket, 126, timeout) do
    with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, timeout), do: {:ok, length}
  end

  defp size(socket, 127, timeout) do
    with {:ok, <<length::64>>} <- :gen_tcp.recv(socket, 8, timeout), do: {:ok, length}
  end

  defp payload(_socket, 0, _timeout), do: {:ok, ""}
  defp payload(socket, size, timeout), do: :gen_tcp.recv(socket, size, timeout)
end
