defmodule Avwe.MCP.Sessions do
  @moduledoc """
  ExMCP's session manager (`ExMCP.SessionManager`), as `ExMCP.HttpPlug`
  uses it, with one addition: when a session is terminated (an MCP client's
  DELETE), its player's Mind ends at once (`Avwe.MCP.Players.ended/1`).
  Expiry is caught by `Avwe.MCP.Players`' sweep.
  """

  alias Avwe.MCP.Players
  alias ExMCP.SessionManager

  defdelegate create_session(metadata), to: SessionManager
  defdelegate ensure_session(session_id, metadata), to: SessionManager
  defdelegate ensure_initialized_session(session_id, metadata), to: SessionManager
  defdelegate claim_request_id(session_id, request_id), to: SessionManager
  defdelegate claim_initialization(session_id), to: SessionManager
  defdelegate complete_initialization(session_id, version), to: SessionManager
  defdelegate update_session(session_id, updates), to: SessionManager
  defdelegate get_session(session_id), to: SessionManager

  @doc "Terminates the session in ExMCP, then ends its player's Mind."
  @spec terminate_session(String.t()) :: :ok
  def terminate_session(session_id) do
    :ok = SessionManager.terminate_session(session_id)
    Players.ended(session_id)
  end
end
