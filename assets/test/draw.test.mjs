// The drawing arithmetic, tested without a browser: `npm test` in assets/.
// The scenes are ones the server builds (test/fixtures, written by
// test/avwe/scene_test.exs), so these check the format it really sends.
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import {
  BACKGROUND,
  brightness,
  cellAtPixel,
  cellRect,
  decodeRow,
  distance,
  factor,
  fog,
  geometry,
  ground,
  inside,
  mirror,
  NEAR,
  ordered,
  paint,
  shade,
  viewport,
} from "../js/draw.js"

const fixture = (name) =>
  JSON.parse(readFileSync(new URL(`./fixtures/${name}.json`, import.meta.url), "utf8"))
const night = fixture("night")
const noon = fixture("noon")

// A canvas context that writes down what it is told, for what `paint` does.
function recorder() {
  const calls = []
  const ctx = {
    calls,
    set fillStyle(value) {
      calls.push(["fillStyle", value])
    },
    set font(value) {
      calls.push(["font", value])
    },
    set textAlign(value) {
      calls.push(["textAlign", value])
    },
    set textBaseline(value) {
      calls.push(["textBaseline", value])
    },
    setTransform: (...args) => calls.push(["setTransform", ...args]),
    fillRect: (...args) => calls.push(["fillRect", ...args]),
    fillText: (...args) => calls.push(["fillText", ...args]),
  }
  return ctx
}

// What was written, in order, with the colour it was written in.
const glyphs = (ctx) => {
  let colour = null
  const written = []
  for (const [call, ...args] of ctx.calls) {
    if (call === "fillStyle") colour = args[0]
    if (call === "fillText") written.push({char: args[0], x: args[1], y: args[2], colour})
  }
  return written
}

describe("decodeRow", () => {
  test("reads runs of a letter and a count", () => {
    assert.deepEqual(decodeRow("g3s2.4"), ["g", "g", "g", "s", "s", ".", ".", ".", "."])
  })

  test("reads a row with several digits in a count, and an empty one", () => {
    assert.equal(decodeRow("g12").length, 12)
    assert.equal(decodeRow(".101").length, 101)
    assert.deepEqual(decodeRow(""), [])
  })

  test("gives each row of a scene the width of its window", () => {
    for (const scene of [night, noon]) {
      for (const row of scene.rows) assert.equal(decodeRow(row).length, scene.size)
      assert.equal(scene.rows.length, scene.size)
    }
  })
})

describe("viewport", () => {
  test("is the whole window when it is no wider than the limit", () => {
    assert.deepEqual(viewport(night, NEAR), {origin: night.origin, size: night.size})
    assert.deepEqual(viewport(noon, 101), {origin: noon.origin, size: 101})
  })

  test("is the cells around the viewer when the window is wider, the viewer in the middle", () => {
    const view = viewport(noon, NEAR)

    assert.equal(view.size, NEAR)
    assert.deepEqual(view.origin, [noon.center[0] - 20, noon.center[1] - 20])
    assert.ok(view.origin[0] >= noon.origin[0] && view.origin[1] >= noon.origin[1])
    assert.ok(view.origin[0] + view.size <= noon.origin[0] + noon.size)
  })

  test("is always odd, so there is a middle cell", () => {
    assert.equal(viewport(noon, 40).size, 41)
  })
})

describe("geometry", () => {
  test("shows the near view, at a size that can be read", () => {
    const geo = geometry(noon, 820)

    assert.equal(geo.zoom, "near")
    assert.equal(geo.size, NEAR)
    assert.equal(geo.cell, 20)
    assert.equal(geo.width, 820)
    assert.equal(geo.height, 820)
    assert.deepEqual(geo.origin, [noon.center[0] - 20, noon.center[1] - 20])
  })

  test("shows the whole window when asked to, however small the cells", () => {
    const geo = geometry(noon, 808, {zoom: "far"})

    assert.equal(geo.zoom, "far")
    assert.equal(geo.size, 101)
    assert.equal(geo.cell, 8)
    assert.deepEqual(geo.origin, noon.origin)
  })

  test("shows all of a window that is small, large, as at night", () => {
    const geo = geometry(night, 440)

    assert.equal(geo.size, 11)
    assert.equal(geo.cell, 40)
    assert.deepEqual(geo.origin, night.origin)
  })

  test("never makes a cell too small to see or bigger than it needs to be", () => {
    assert.equal(geometry(noon, 100, {zoom: "far"}).cell, 4)
    assert.equal(geometry(night, 2000).cell, 40)
    assert.equal(geometry(night, 2000).width, 40 * night.size)
  })

  test("takes the limits it is given", () => {
    assert.equal(geometry(noon, 100, {zoom: "far", min: 2}).cell, 2)
    assert.equal(geometry(night, 2000, {max: 60}).cell, 60)
    assert.equal(geometry(noon, 900, {near: 21}).size, 21)
  })
})

describe("inside", () => {
  test("says whether a cell is in the view", () => {
    const geo = geometry(noon, 820)
    const [ox, oy] = geo.origin

    assert.ok(inside(geo, [ox, oy]))
    assert.ok(inside(geo, noon.center))
    assert.ok(inside(geo, [ox + 40, oy + 40]))
    assert.ok(!inside(geo, [ox - 1, oy]))
    assert.ok(!inside(geo, [ox, oy + 41]))
    assert.ok(!inside(geo, [ox + 41, oy]))
  })
})

describe("cells and pixels", () => {
  const geo = geometry(night, 11 * 10)

  test("puts the window's first cell at the top left", () => {
    assert.deepEqual(cellRect(geo, night.origin), {x: 0, y: 0, size: 10})
    assert.deepEqual(cellRect(geo, [night.origin[0] + 3, night.origin[1] + 2]), {x: 30, y: 20, size: 10})
  })

  test("finds the cell of a pixel, which is the cell that has it", () => {
    for (const [x, y] of [[0, 0], [3, 2], [10, 10], [5, 5]]) {
      const cell = [night.origin[0] + x, night.origin[1] + y]
      const rect = cellRect(geo, cell)
      for (const [dx, dy] of [[0, 0], [9, 9], [4, 7]]) {
        assert.deepEqual(cellAtPixel(geo, rect.x + dx, rect.y + dy), cell)
      }
    }
  })

  test("finds no cell for a pixel outside the window", () => {
    for (const [x, y] of [[-1, 5], [5, -1], [110, 5], [5, 110], [1000, 1000]]) {
      assert.equal(cellAtPixel(geo, x, y), null)
    }
  })

  test("the viewer's own cell is the middle of the window", () => {
    const rect = cellRect(geo, night.center)
    assert.deepEqual([rect.x, rect.y], [50, 50])
  })
})

describe("light", () => {
  test("is dimmest at night and brightest at noon, and never black", () => {
    assert.equal(brightness(1), 1)
    assert.ok(brightness(0) > 0.3 && brightness(0) < 0.4)
    assert.ok(brightness(0.5) > brightness(0.2))
  })

  test("takes a light outside 0 to 1 as the nearest end of it", () => {
    assert.equal(brightness(-3), brightness(0))
    assert.equal(brightness(7), 1)
  })

  test("fog is none at the centre, most at the rim, and no more beyond it", () => {
    assert.equal(fog(0, 50), 1)
    assert.ok(fog(25, 50) < 1 && fog(25, 50) > fog(50, 50))
    assert.equal(fog(50, 50), fog(500, 50))
    assert.equal(fog(0, 0), 1)
  })

  test("shades a colour by a factor, channel by channel", () => {
    assert.equal(shade("#ffffff", 1), "#ffffff")
    assert.equal(shade("#ffffff", 0), "#000000")
    assert.equal(shade("#ff8040", 0.5), "#804020")
    assert.equal(shade("#102030", 2), "#102030")
    assert.equal(shade("#102030", -1), "#000000")
  })

  test("dims what the dark and the distance dim, and leaves what lights itself", () => {
    const cell = [night.center[0] + 3, night.center[1]]

    assert.ok(factor(night, "grass", cell) < factor(noon, "grass", cell))
    assert.ok(factor(night, "grass", cell) < factor(night, "grass", night.center))
    assert.equal(factor(night, "hearth_burning", cell), 1)
    assert.equal(factor(night, "glow", [night.center[0] + 40, night.center[1]]), 1)
  })

  test("measures distance in cells", () => {
    assert.equal(distance([0, 0], [3, 4]), 5)
  })
})

describe("ground", () => {
  test("is each cell that is not blank, where the window puts it, with its glyph", () => {
    const cells = ground(night)
    const seen = night.rows.flatMap((row) => decodeRow(row)).filter((letter) => letter !== ".")

    assert.equal(cells.length, seen.length)
    assert.ok(cells.length > 0 && cells.length < night.size * night.size)

    const centre = cells.find(({cell}) => cell[0] === night.center[0] && cell[1] === night.center[1])
    assert.equal(centre.kind, "clay")
    assert.deepEqual(centre.glyph, night.legend.clay.glyph)
  })

  test("is nothing outside the circle of sight, because the scene says nothing there", () => {
    for (const {cell} of ground(night)) {
      assert.ok(distance(cell, night.center) <= night.radius + 0.5)
    }
  })

  test("is nothing at all in a world with no ground", () => {
    assert.deepEqual(ground({...night, rows: null}), [])
  })

  test("leaves out a kind the legend does not know", () => {
    const legend = {...night.legend}
    delete legend.clay

    assert.ok(ground({...night, legend}).every(({kind}) => kind !== "clay"))
  })
})

describe("ordered", () => {
  test("puts a body over a fire over a place, and settles the rest by id", () => {
    const thing = (id, kind) => ({id, kind})
    const things = [thing("b", "body"), thing("p", "place"), thing("z", "hearth"), thing("a", "hearth_burning"), thing("s", "smoke")]

    assert.deepEqual(ordered(things).map(({id}) => id), ["p", "a", "z", "s", "b"])
  })

  test("does not change what it is given", () => {
    const things = [{id: "b", kind: "body"}, {id: "p", kind: "place"}]
    ordered(things)

    assert.deepEqual(things.map(({id}) => id), ["b", "p"])
  })
})

describe("paint", () => {
  const geo = geometry(night, 11 * 12)

  test("clears the canvas to its background before it draws anything", () => {
    const ctx = recorder()
    paint(ctx, night, geo, 2)

    assert.deepEqual(ctx.calls[0], ["setTransform", 2, 0, 0, 2, 0, 0])
    assert.deepEqual(ctx.calls[1], ["fillStyle", BACKGROUND])
    assert.deepEqual(ctx.calls[2], ["fillRect", 0, 0, geo.width, geo.height])
  })

  test("writes each glyph in the middle of its cell, in a monospace face", () => {
    const ctx = recorder()
    paint(ctx, night, geo)

    const font = ctx.calls.find(([call]) => call === "font")[1]
    assert.match(font, /monospace$/)
    assert.deepEqual(ctx.calls.find(([call]) => call === "textAlign"), ["textAlign", "center"])
    assert.deepEqual(ctx.calls.find(([call]) => call === "textBaseline"), ["textBaseline", "middle"])

    const last = glyphs(ctx).at(-1)
    const rect = cellRect(geo, night.center)
    assert.equal(last.x, rect.x + rect.size / 2)
    assert.equal(last.y, rect.y + rect.size / 2)
  })

  test("draws the ground, then the things, then the viewer last", () => {
    const ctx = recorder()
    paint(ctx, night, geo)
    const written = glyphs(ctx)

    assert.equal(written.length, ground(night).length + night.things.length + 1)
    assert.equal(written.at(-1).char, night.you.glyph.char)

    const fire = night.things.find(({id}) => id === "town-hearth")
    const place = night.things.find(({id}) => id === "ember-reach")
    const order = written.map(({char}) => char)
    assert.ok(order.lastIndexOf(place.glyph.char) < order.lastIndexOf(fire.glyph.char))
    assert.ok(order.lastIndexOf(fire.glyph.char) < order.length - 1)
  })

  test("draws nothing for a cell the scene leaves blank", () => {
    const ctx = recorder()
    paint(ctx, night, geo)
    const written = glyphs(ctx)
    const blank = night.rows.flatMap((row, dy) => decodeRow(row).map((letter, dx) => [letter, dx, dy])).filter(([letter]) => letter === ".")

    assert.ok(blank.length > 0)
    for (const [, dx, dy] of blank) {
      const cell = [night.origin[0] + dx, night.origin[1] + dy]
      const rect = cellRect(geo, cell)
      assert.ok(!written.some(({x, y}) => x === rect.x + rect.size / 2 && y === rect.y + rect.size / 2))
    }
  })

  test("draws the same ground dimmer at night than at noon", () => {
    const at = (scene) => {
      const ctx = recorder()
      paint(ctx, scene, geometry(scene, scene.size * 12))
      return glyphs(ctx)
    }
    const channel = (colour) => parseInt(colour.slice(1, 3), 16)
    const clay = (scene) => at(scene).find(({char}) => char === ":")

    assert.ok(channel(clay(night).colour) < channel(clay(noon).colour))
  })

  test("leaves a fire's own light as bright as it is, in the dark", () => {
    const ctx = recorder()
    paint(ctx, night, geo)

    const fire = night.things.find(({id}) => id === "town-hearth")
    const drawn = glyphs(ctx).filter(({char}) => char === fire.glyph.char).at(-1)
    assert.equal(drawn.colour, fire.glyph.color)
  })

  test("draws only what is in the view: the near view of noon leaves out the rest of the window", () => {
    const near = recorder()
    paint(near, noon, geometry(noon, 820))
    const far = recorder()
    paint(far, noon, geometry(noon, 808, {zoom: "far"}))

    assert.ok(glyphs(near).length < glyphs(far).length)
    assert.ok(glyphs(near).length <= NEAR * NEAR + noon.things.length + 1)
    assert.ok(glyphs(near).every(({x, y}) => x >= 0 && x < 820 && y >= 0 && y < 820))
  })

  test("draws a world with no ground: its things, and the viewer", () => {
    const ctx = recorder()
    const bare = {...noon, rows: null, legend: {...noon.legend}}
    paint(ctx, bare, geometry(bare, 808, {zoom: "far"}))

    assert.equal(glyphs(ctx).length, bare.things.length + 1)
  })
})

describe("mirror", () => {
  test("says what was drawn, as strings a page can carry in data attributes", () => {
    const state = mirror(night, geometry(night, 440))

    assert.equal(state.drawnCenter, night.center.join(","))
    assert.equal(state.drawnRadius, "5")
    assert.equal(state.drawnLight, "0")
    assert.equal(state.drawnTime, String(night.time))
    assert.equal(state.drawnCells, String(ground(night).length))
    assert.equal(state.drawnThings, "ember-reach,town-hearth")
    assert.equal(state.drawnZoom, "near")
    assert.equal(state.drawnShown, "11")
    assert.equal(state.drawnCellPixels, "40")
    assert.ok(Object.values(state).every((value) => typeof value === "string"))
  })
})
