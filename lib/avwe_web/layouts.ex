defmodule AvweWeb.Layouts do
  @moduledoc "The page every view is rendered into."

  use AvweWeb, :html

  embed_templates "layouts/*"
end
