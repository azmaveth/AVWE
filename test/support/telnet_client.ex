defmodule Avwe.Test.TelnetClient do
  @moduledoc """
  A telnet player for end-to-end tests. It connects over real TCP, sends
  lines, and reads what the server writes back.
  """

  import ExUnit.Assertions

  @doc "Connects to a telnet server on localhost."
  def connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, packet: :line, active: false])
    socket
  end

  @doc "Sends one line, as a player pressing Enter."
  def send_line(socket, line), do: :ok = :gen_tcp.send(socket, line <> "\r\n")

  @doc """
  Reads lines until one matches `pattern` (a string to look for, or a regex).
  Returns every line read, the matching one last. Fails after `timeout` ms.
  """
  def expect(socket, pattern, timeout \\ 1_000) do
    read_until(socket, pattern, System.monotonic_time(:millisecond) + timeout, [])
  end

  @doc "Reads for `wait` ms and fails if any line matches `pattern`. Returns the lines read."
  def refute_line(socket, pattern, wait \\ 150) do
    lines = read_for(socket, System.monotonic_time(:millisecond) + wait, [])

    refute Enum.any?(lines, &(&1 =~ pattern)),
           "Didn't expect #{inspect(pattern)}, got:\n#{Enum.join(lines, "\n")}"

    lines
  end

  @doc """
  Waits until the server has handled every line sent so far, by asking the
  time and reading up to the answer. Lines are handled in order, so after this
  an earlier command's intent is in the world. Call it straight after
  commands, before stepping the world, so no percepts are skipped. Asking
  the time counts as presence, so a sync also re-arms the session's idle
  timer; do not sync between a command and a yield you expect.
  """
  def sync(socket) do
    send_line(socket, "time")
    expect(socket, ~r/^\d+ AR, day \d+, \d\d:\d\d$/)
    :ok
  end

  @doc "True once the server has closed the connection."
  def closed?(socket), do: drain_to_close(socket) == :closed

  @doc "Connects, chooses a body (or \"watch\"), and waits until the player is in."
  def join(port, choice, joined \\ ~r/^You (are|see|know)/) do
    socket = connect(port)
    expect(socket, "Who will you be?")
    expect(socket, "watch without a body")
    send_line(socket, choice)
    expect(socket, joined)
    socket
  end

  defp read_until(socket, pattern, deadline, seen) do
    case :gen_tcp.recv(socket, 0, remaining(deadline)) do
      {:ok, line} ->
        seen = [String.trim_trailing(line) | seen]

        if hd(seen) =~ pattern,
          do: Enum.reverse(seen),
          else: read_until(socket, pattern, deadline, seen)

      {:error, reason} ->
        flunk(
          "Waiting for #{inspect(pattern)}, got #{reason} after:\n#{seen |> Enum.reverse() |> Enum.join("\n")}"
        )
    end
  end

  defp read_for(socket, deadline, seen) do
    case :gen_tcp.recv(socket, 0, remaining(deadline)) do
      {:ok, line} -> read_for(socket, deadline, [String.trim_trailing(line) | seen])
      {:error, _reason} -> Enum.reverse(seen)
    end
  end

  defp drain_to_close(socket) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, _line} -> drain_to_close(socket)
      {:error, :closed} -> :closed
      {:error, reason} -> reason
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
