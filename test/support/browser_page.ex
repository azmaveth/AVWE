defmodule Avwe.Test.BrowserPage do
  @moduledoc """
  What a browser test of the watch page (`test/browser`) reads from the page it
  drives, and does to it, beyond what `PhoenixTest.Playwright` offers: the
  attributes the hook writes on the canvas, the canvas's own pixels, and the
  pointer. A canvas is read at its whole-valley view (zoom 0, no pan), where a
  cell's place on it is its cell number times the size of a cell.
  """

  alias PlaywrightEx.{Frame, Page}

  @canvas "#world"

  # How long a call may take: what the browser tests are configured to wait for
  # a page (`PW_TIMEOUT_S`, longer on a slow runner).
  defp timeout,
    do: :phoenix_test |> Application.get_env(:playwright, []) |> Keyword.get(:timeout, 5_000)

  @doc "Evaluates JavaScript in the page and gives back what it returns."
  @spec js(map(), String.t()) :: term()
  def js(conn, expression) do
    {:ok, value} = Frame.evaluate(conn.frame_id, expression: expression, timeout: timeout())
    value
  end

  # Calls a JavaScript function in the page with one argument.
  defp call(conn, function, arg) do
    {:ok, value} =
      Frame.evaluate(conn.frame_id,
        expression: function,
        is_function: true,
        arg: arg,
        timeout: timeout()
      )

    value
  end

  @doc "What the hook wrote on the canvas once it had drawn (`data-drawn-*`)."
  @spec drawn(map()) :: %{String.t() => String.t()}
  def drawn(conn) do
    js(conn, """
    Object.fromEntries(
      Object.entries(document.querySelector('#{@canvas}').dataset).filter(([name]) => name.startsWith('drawn'))
    )
    """)
  end

  @doc "The scene the server gave the canvas."
  @spec scene(map()) :: map()
  def scene(conn), do: js(conn, "JSON.parse(document.querySelector('#{@canvas}').dataset.scene)")

  @doc "The ground the server gave the canvas."
  @spec ground(map()) :: map()
  def ground(conn),
    do: js(conn, "JSON.parse(document.querySelector('#{@canvas}').dataset.ground)")

  @doc "How many pixels a cell takes on the canvas, at its whole-valley view."
  @spec cell_pixels(map()) :: float()
  def cell_pixels(conn) do
    call(
      conn,
      """
      () => {
        const canvas = document.querySelector('#{@canvas}')
        return canvas.clientWidth / Number(canvas.dataset.drawnGround.split('x')[0])
      }
      """,
      nil
    )
  end

  @doc """
  The colour at the middle of each of `cells` on the canvas, as `{r, g, b}`, at
  its whole-valley view.
  """
  @spec pixels(map(), [{integer(), integer()}]) :: [{0..255, 0..255, 0..255}]
  def pixels(conn, cells) do
    conn
    |> call(
      """
      (cells) => {
        const canvas = document.querySelector('#{@canvas}')
        if (canvas.dataset.drawnZoom !== '0' || canvas.dataset.drawnPan !== '0,0') {
          throw new Error('pixels are read at the whole valley')
        }
        const scale = canvas.width / canvas.clientWidth
        const cell = (canvas.clientWidth / Number(canvas.dataset.drawnGround.split('x')[0])) * scale
        const context = canvas.getContext('2d')
        return cells.map(([x, y]) =>
          Array.from(
            context.getImageData(Math.floor((x + 0.5) * cell), Math.floor((y + 0.5) * cell), 1, 1).data.slice(0, 3)
          )
        )
      }
      """,
      Enum.map(cells, &Tuple.to_list/1)
    )
    |> Enum.map(&List.to_tuple/1)
  end

  @doc """
  What the page shows at one moment, read in one go so that the parts agree: the
  hook's mirror (`data-drawn-*`), the time and the things of the scene the canvas
  was given, and the colour at the middle of each of `cells`, at the whole-valley
  view. When the mirror's time is the scene's, the canvas shows that scene.
  """
  @spec observe(map(), [{integer(), integer()}]) :: %{
          drawn: %{String.t() => String.t()},
          time: integer(),
          things: [{integer(), integer()}],
          pixels: [{0..255, 0..255, 0..255}]
        }
  def observe(conn, cells) do
    %{"drawn" => drawn, "time" => time, "things" => things, "pixels" => pixels} =
      call(
        conn,
        """
        (cells) => {
          const canvas = document.querySelector('#{@canvas}')
          const scene = JSON.parse(canvas.dataset.scene)
          const drawn = Object.fromEntries(
            Object.entries(canvas.dataset).filter(([name]) => name.startsWith('drawn'))
          )
          const scale = canvas.width / canvas.clientWidth
          const cell = (canvas.clientWidth / Number(canvas.dataset.drawnGround.split('x')[0])) * scale
          const context = canvas.getContext('2d')
          const pixels = cells.map(([x, y]) =>
            Array.from(
              context.getImageData(Math.floor((x + 0.5) * cell), Math.floor((y + 0.5) * cell), 1, 1).data.slice(0, 3)
            )
          )
          return {drawn, time: scene.time, things: scene.things.map((thing) => thing.cell), pixels}
        }
        """,
        Enum.map(cells, &Tuple.to_list/1)
      )

    %{
      drawn: drawn,
      time: time,
      things: Enum.map(things, &List.to_tuple/1),
      pixels: Enum.map(pixels, &List.to_tuple/1)
    }
  end

  @doc "How many pixels of the canvas are lit: any channel over 40."
  @spec lit(map()) :: non_neg_integer()
  def lit(conn) do
    js(conn, """
    (() => {
      const canvas = document.querySelector('#{@canvas}')
      const data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data
      let lit = 0
      for (let i = 0; i < data.length; i += 4) if (data[i] > 40 || data[i + 1] > 40 || data[i + 2] > 40) lit++
      return lit
    })()
    """)
  end

  @doc "Where, in the canvas, the middle of a cell is, at its whole-valley view."
  @spec position(map(), {integer(), integer()}) :: %{x: float(), y: float()}
  def position(conn, {x, y}) do
    cell = cell_pixels(conn)
    %{x: (x + 0.5) * cell, y: (y + 0.5) * cell}
  end

  @doc "A mouse click on the canvas, at a place in it (pixels from its top left)."
  @spec click_at(map(), %{x: number(), y: number()}) :: map()
  def click_at(conn, position) do
    {:ok, _} =
      Frame.click(conn.frame_id, selector: @canvas, position: position, timeout: timeout())

    conn
  end

  @doc """
  A drag of the mouse across the canvas, as a hand does it: down at one place,
  a few moves, up at another (pixels from the canvas's top left).
  """
  @spec drag_across(map(), %{x: number(), y: number()}, %{x: number(), y: number()}) :: map()
  def drag_across(conn, from, to) do
    %{"left" => left, "top" => top} =
      js(conn, """
      (() => {
        const canvas = document.querySelector('#{@canvas}')
        const box = canvas.getBoundingClientRect()
        return {left: box.left + canvas.clientLeft, top: box.top + canvas.clientTop}
      })()
      """)

    at = fn %{x: x, y: y} -> [x: left + x, y: top + y, timeout: timeout()] end
    {:ok, _} = Page.mouse_move(conn.page_id, at.(from))
    {:ok, _} = Page.mouse_down(conn.page_id, timeout: timeout())

    for step <- 1..5 do
      t = step / 5

      {:ok, _} =
        Page.mouse_move(
          conn.page_id,
          at.(%{x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t})
        )
    end

    {:ok, _} = Page.mouse_up(conn.page_id, timeout: timeout())
    conn
  end

  @doc """
  `times` turns of the mouse wheel over the canvas at a place in it, all in the
  same moment: `delta` below zero is away from the hand, which zooms in.
  """
  @spec wheel(map(), %{x: number(), y: number()}, number(), pos_integer()) :: map()
  def wheel(conn, %{x: x, y: y}, delta, times \\ 1) do
    call(
      conn,
      """
      ({x, y, delta, times}) => {
        const canvas = document.querySelector('#{@canvas}')
        const box = canvas.getBoundingClientRect()
        for (let n = 0; n < times; n++) {
          canvas.dispatchEvent(
            new WheelEvent('wheel', {
              deltaY: delta,
              clientX: box.left + canvas.clientLeft + x,
              clientY: box.top + canvas.clientTop + y,
              bubbles: true,
              cancelable: true
            })
          )
        }
      }
      """,
      %{x: x, y: y, delta: delta, times: times}
    )

    conn
  end
end
