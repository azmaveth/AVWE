defmodule Avwe.Test.HTTPClient do
  @moduledoc """
  One bare HTTP/1.1 request over a socket, for end-to-end tests of the web
  client. The test chooses the headers, so it can send what a page that is not
  ours would: another `Host`, another `Origin`.

  A response is read until its body is as long as it says, and an upgrade
  (`101`) as soon as its head has arrived.
  """

  @type response :: %{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: String.t()
        }

  @doc """
  Sends `method path` to `127.0.0.1:port`. `Host` is that address, and the
  connection closes after the response, unless `headers` say otherwise.
  Header names are lower-cased in the response.
  """
  @spec request(:inet.port_number(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          response()
  def request(port, method, path, headers \\ []) do
    {socket, response} = open(port, method, path, headers)
    :ok = :gen_tcp.close(socket)
    response
  end

  @doc """
  Like `request/4`, but leaves the socket open and returns it with the
  response, for an upgrade to a websocket.
  """
  @spec open(:inet.port_number(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:gen_tcp.socket(), response()}
  def open(port, method, path, headers \\ []) do
    defaults = %{"host" => "127.0.0.1:#{port}", "connection" => "close"}

    sent =
      Map.merge(
        defaults,
        Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
      )

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    head = [
      "#{method} #{path} HTTP/1.1\r\n",
      for({name, value} <- sent, do: "#{name}: #{value}\r\n"),
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, head)
    {socket, socket |> read("") |> parse()}
  end

  defp read(socket, received) do
    if complete?(received) do
      received
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> read(socket, received <> data)
        {:error, :closed} -> received
      end
    end
  end

  # The head has arrived and nothing more is to come: a switch of protocols
  # has no end to wait for, and a body ends where its length says.
  defp complete?(received) do
    case String.split(received, "\r\n\r\n", parts: 2) do
      [head, body] ->
        String.starts_with?(head, "HTTP/1.1 101") or
          case Regex.run(~r/\r\ncontent-length: *(\d+)/i, head) do
            [_, length] -> byte_size(body) >= String.to_integer(length)
            nil -> false
          end

      [_incomplete] ->
        false
    end
  end

  defp parse(received) do
    [head, body] = String.split(received, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status | _reason] = String.split(status_line, " ", parts: 3)

    headers =
      for line <- header_lines do
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end

    %{status: String.to_integer(status), headers: headers, body: body}
  end
end
