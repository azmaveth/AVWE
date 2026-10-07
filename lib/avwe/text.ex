defmodule Avwe.Text do
  @moduledoc """
  What a player may put in words: one line of plain text. Pure.

  Speech, notebook pages and a guest's name and backstory come from
  somebody else's controller, and reach other players' terminals, pages and
  prompts. So terminal escape sequences are dropped whole, line breaks and
  tabs become single spaces, and every other control character is dropped,
  before anything is measured: nobody's words can forge the lines another
  player is told in, or reach a terminal as a command.
  """

  # Line breaks and tabs, as regex class members: what a line turns into a space.
  @breaks "\\t\\r\\n\\v\\f\\x{85}\\x{2028}\\x{2029}"
  # Terminal escape sequences: CSI (`ESC [ ... final`), OSC (`ESC ] ...`
  # ended by BEL or ST, or by nothing) and the two-character kind.
  @escapes ~r/\e(?:\[[0-?]*[ -\/]*[@-~]|\][^\a\e]*(?:\a|\e\\)?|[@-Z\\-_])/u

  @doc """
  The text with escape sequences dropped whole, line breaks and tabs made
  single spaces, and other control characters dropped. Text that is not valid
  UTF-8 is dropped altogether, and anything that is not text is returned as
  it is.
  """
  @spec clean(term()) :: term()
  def clean(text) when is_binary(text) do
    if String.valid?(text) do
      text
      |> String.replace(@escapes, "")
      |> String.replace(~r/[ #{@breaks}]*[#{@breaks}][ #{@breaks}]*/u, " ")
      |> String.replace(~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u, "")
    else
      ""
    end
  end

  def clean(other), do: other

  @doc "`clean/1`, trimmed; `\"\"` for anything that is not text."
  @spec line(term()) :: String.t()
  def line(text) do
    case clean(text) do
      cleaned when is_binary(cleaned) -> String.trim(cleaned)
      _not_text -> ""
    end
  end
end
