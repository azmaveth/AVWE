defmodule Avwe.TextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Avwe.Text

  describe "clean/1" do
    test "drops terminal escape sequences whole" do
      assert Text.clean("hello \e[31mred\e[0m world") == "hello red world"
      assert Text.clean("a\e]0;a title\ab") == "ab"
      assert Text.clean("a\e]0;a title\e\\b") == "ab"
      assert Text.clean("a\eDb") == "ab"
    end

    test "makes line breaks and tabs single spaces" do
      assert Text.clean("one\ntwo\r\nthree\tfour") == "one two three four"
      assert Text.clean("one \n two") == "one two"
      assert Text.clean("a\u2028b\u2029c\u0085d") == "a b c d"
    end

    test "drops the other control characters" do
      assert Text.clean("a\0b\x07c\x7fd\u009fe") == "abcde"
    end

    test "drops text that is not valid UTF-8, and returns what is not text as it is" do
      assert Text.clean(<<0xFF, 0xFE>>) == ""
      assert Text.clean(nil) == nil
      assert Text.clean(12) == 12
    end
  end

  describe "line/1" do
    test "is clean text, trimmed" do
      assert Text.line("  \n a line \t ") == "a line"
    end

    test "is an empty line for anything that is not text" do
      assert Text.line(nil) == ""
      assert Text.line(12) == ""
      assert Text.line(<<0xFF>>) == ""
    end

    property "never holds a line break or a control character, whatever it is given" do
      check all(text <- StreamData.string(:printable, max_length: 40)) do
        line = Text.line(text <> "\e[2J\n\0" <> text)
        refute line =~ ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}\x{2028}\x{2029}]/u
        assert line == String.trim(line)
      end
    end
  end
end
