// The spectator's drawing arithmetic, tested without a browser: `npm test` in
// assets/. The ground and the scenes are ones the server builds (written by
// test/avwe/world_scene_test.exs), so these check the format it really sends.
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {describe, test} from "node:test"

import {BACKGROUND, brightness, decodeRow, shade} from "../js/draw.js"
import {
  cellAt,
  DEFAULT_OVERLAYS,
  GLYPH_FROM,
  GROUND_KINDS,
  groundColors,
  groundGrid,
  heatColorAt,
  heatColors,
  heatGrid,
  heatTemp,
  mirrorWorld,
  OVERLAYS,
  paintWorld,
  panned,
  pickRadius,
  pixelOf,
  prepareGround,
  prepareScene,
  puffRadius,
  rampColor,
  span,
  viewGeometry,
  visible,
  ZOOMS,
  zoomed,
} from "../js/world.js"

const fixture = (name) =>
  JSON.parse(readFileSync(new URL(`./fixtures/${name}.json`, import.meta.url), "utf8"))
const groundData = fixture("world_ground")
const flowing = fixture("world_flowing")
const drying = fixture("world_drying")
const prepared = prepareGround(groundData)
const worldOf = (scene) => prepareScene(prepared, scene)
const MAP = {width: groundData.width, height: groundData.height}
const WIDTH = 768

// A canvas context that writes down what it is told, with the colour and the
// opacity it had when it was told.
function recorder() {
  const state = {fillStyle: null, strokeStyle: null, globalAlpha: 1}
  const calls = []
  const note = (op, ...args) => calls.push({op, args, ...state})
  return {
    calls,
    set fillStyle(value) {
      state.fillStyle = value
    },
    set strokeStyle(value) {
      state.strokeStyle = value
    },
    set globalAlpha(value) {
      state.globalAlpha = value
    },
    set lineWidth(_value) {},
    set font(value) {
      state.font = value
    },
    set textAlign(_value) {},
    set textBaseline(_value) {},
    setTransform: (...args) => note("setTransform", ...args),
    fillRect: (...args) => note("fillRect", ...args),
    fillText: (...args) => note("fillText", ...args),
    beginPath: () => note("beginPath"),
    arc: (...args) => note("arc", ...args),
    fill: () => note("fill"),
    stroke: () => note("stroke"),
  }
}

const ops = (ctx, op) => ctx.calls.filter((call) => call.op === op)
const rects = (ctx) => ops(ctx, "fillRect")
const paint = (world, geo, on = DEFAULT_OVERLAYS) => {
  const ctx = recorder()
  paintWorld(ctx, world, geo, on)
  return ctx
}
const fit = viewGeometry(WIDTH, MAP)

describe("decodeRow with capitals", () => {
  test("reads a level written as a capital as it reads one written as a small letter", () => {
    assert.deepEqual(decodeRow("a2B3.2Z1"), ["a", "a", "B", "B", "B", ".", ".", "Z"])
  })
})

describe("the ground", () => {
  const grid = groundGrid(groundData)

  test("is a byte for each cell, the letter of the row's code", () => {
    assert.equal(grid.length, MAP.width * MAP.height)
    const row = decodeRow(groundData.rows[5])
    for (let x = 0; x < MAP.width; x++) {
      assert.equal(String.fromCharCode(grid[5 * MAP.width + x]), row[x])
    }
  })

  test("is made of the ground's own letters, and the bed is the river's cells", () => {
    const letters = new Set([...grid].map((code) => String.fromCharCode(code)))
    for (const letter of letters) assert.ok(letter in GROUND_KINDS, letter)
    const bed = [...grid].filter((code) => code === "b".charCodeAt(0)).length
    assert.equal(bed, groundData.reaches.flat().length)
    assert.ok(bed > 600)
  })

  test("is drawn in the colour of each kind's legend, darkened", () => {
    const colors = groundColors(groundData)
    for (const [letter, kind] of Object.entries(GROUND_KINDS)) {
      const glyph = groundData.legend[kind]?.glyph
      assert.equal(colors[letter], glyph ? shade(glyph.color, 0.6) : undefined, kind)
    }
    assert.ok(Object.keys(colors).length >= 4)
  })
})

describe("the heat", () => {
  const heat = flowing.overlays.heat
  const grid = heatGrid(heat, MAP.width, MAP.height)

  test("is the level of each cell the server stores, and -1 for each it does not", () => {
    const stored = heat.rows.flatMap((row) => decodeRow(row)).filter((symbol) => symbol !== ".")
    assert.equal(grid.filter((level) => level >= 0).length, stored.length)
    assert.ok(stored.length > 3000)

    const first = heat.rows.findIndex((row) => row !== `.${MAP.width}`)
    const symbols = decodeRow(heat.rows[first])
    symbols.forEach((symbol, x) => {
      const level = grid[first * MAP.width + x]
      assert.equal(level, symbol === "." ? -1 : "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".indexOf(symbol))
    })
  })

  test("has a level in the fifty-two the server writes", () => {
    for (const level of grid) assert.ok(level >= -1 && level <= 51)
  })

  test("is a temperature from the base and the step: a level is a degree", () => {
    assert.equal(heatTemp(heat, 0), -10)
    assert.equal(heatTemp(heat, 10), 0)
    assert.equal(heatTemp(heat, 51), 41)
  })

  test("is coloured by the ramp: the ends for what is beyond them, a mix between", () => {
    const [cold, warm] = heat.ramp
    assert.equal(rampColor(heat.ramp, cold.at - 100), cold.color)
    assert.equal(rampColor(heat.ramp, cold.at), cold.color)
    assert.equal(rampColor(heat.ramp, heat.ramp.at(-1).at + 100), heat.ramp.at(-1).color)
    assert.equal(rampColor(heat.ramp, warm.at), warm.color)

    const half = rampColor(heat.ramp, (cold.at + warm.at) / 2)
    const channels = (hex) => [1, 3, 5].map((at) => parseInt(hex.slice(at, at + 2), 16))
    channels(half).forEach((channel, i) => {
      const mean = (channels(cold.color)[i] + channels(warm.color)[i]) / 2
      assert.ok(Math.abs(channel - mean) <= 1, `${i}: ${channel} against ${mean}`)
    })
  })

  test("is a mix in proportion to where the value lies between two stops, not always a half", () => {
    const ramp = [{at: 0, color: "#000000"}, {at: 30, color: "#ff0000"}, {at: 40, color: "#ffffff"}]
    assert.equal(rampColor(ramp, 10), "#550000")
    assert.equal(rampColor(ramp, 15), "#800000")
    assert.equal(rampColor(ramp, 20), "#aa0000")
    assert.equal(rampColor(ramp, 32), "#ff3333")
  })

  test("gives a cell the server stores its own level's colour, and any other its ground's background", () => {
    const world = worldOf(flowing)
    const {levels, backgrounds} = world.heatPalette
    assert.notEqual(backgrounds.grass, backgrounds.stone)

    const find = (letter, stored) => {
      for (let at = 0; at < world.grid.length; at++) {
        const is = world.grid[at] === letter.charCodeAt(0)
        if (is && (world.heatGrid[at] >= 0) === stored) return [at % MAP.width, Math.floor(at / MAP.width)]
      }
    }

    const [sx, sy] = find("t", false)
    assert.equal(heatColorAt(world, sx, sy), backgrounds.stone)
    const [gx, gy] = find("g", false)
    assert.equal(heatColorAt(world, gx, gy), backgrounds.grass)

    const [bx, by] = find("s", true)
    assert.equal(heatColorAt(world, bx, by), levels[world.heatGrid[by * MAP.width + bx]])
  })

  test("has a colour for each of its levels and each background", () => {
    const palette = heatColors(heat)
    assert.equal(palette.levels.length, 52)
    assert.equal(palette.levels[0], rampColor(heat.ramp, -10))
    assert.equal(palette.levels[30], rampColor(heat.ramp, 20))
    assert.equal(palette.backgrounds.grass, rampColor(heat.ramp, heat.backgrounds.grass))
    assert.equal(palette.backgrounds.stone, rampColor(heat.ramp, heat.backgrounds.stone))
  })
})

describe("the window", () => {
  test("fits the whole map in the width at zoom 0, and doubles the cell at each step", () => {
    assert.equal(fit.cell, 3)
    assert.deepEqual([fit.width, fit.height], [768, 768])
    assert.deepEqual(fit.view, [256, 256])
    assert.deepEqual(fit.pan, [0, 0])

    ZOOMS.forEach((multiple, zoom) => {
      const geo = viewGeometry(WIDTH, MAP, zoom)
      assert.equal(geo.cell, 3 * multiple)
      assert.deepEqual(geo.view, [256 / multiple, 256 / multiple])
    })
  })

  test("keeps the pan on the map, and the zoom on its steps", () => {
    assert.deepEqual(viewGeometry(WIDTH, MAP, 1, [500, -4]).pan, [128, 0])
    assert.deepEqual(viewGeometry(WIDTH, MAP, 0, [30, 30]).pan, [0, 0])
    assert.equal(viewGeometry(WIDTH, MAP, 9).zoom, ZOOMS.length - 1)
    assert.equal(viewGeometry(WIDTH, MAP, -2).zoom, 0)
  })

  test("is as tall as the map is, for a map that is not square", () => {
    const geo = viewGeometry(600, {width: 120, height: 60})
    assert.deepEqual([geo.width, geo.height], [600, 300])
    assert.equal(geo.cell, 5)
  })

  test("says which cells are in it: all of them at zoom 0, a part when it is zoomed", () => {
    assert.deepEqual(visible(fit), {x: [0, 256], y: [0, 256]})
    const near = viewGeometry(WIDTH, MAP, 3, [10.5, 20.25])
    assert.deepEqual(visible(near), {x: [10, 43], y: [20, 53]})
  })
})

describe("cells and pixels", () => {
  const geo = viewGeometry(WIDTH, MAP, 2, [37.5, 90.25])

  test("agree: the pixel at a cell's corner is in that cell", () => {
    for (const cell of [[40, 92], [60, 100], [99, 120]]) {
      const [px, py] = pixelOf(geo, cell)
      assert.ok(px >= 0 && py >= 0 && px < geo.width && py < geo.height)
      assert.deepEqual(cellAt(geo, px + 0.01, py + 0.01), cell)
    }
  })

  test("put a cell that is scrolled off before the canvas, at a negative pixel", () => {
    const [px] = pixelOf(geo, [37, 90])
    assert.ok(px < 0)
  })

  test("have nothing outside the canvas", () => {
    for (const [x, y] of [[-1, 5], [5, -1], [WIDTH, 5], [5, WIDTH]]) {
      assert.equal(cellAt(geo, x, y), null)
    }
  })

  test("map the top left pixel to the cell the window is panned to", () => {
    assert.deepEqual(cellAt(geo, 0, 0), [37, 90])
    assert.deepEqual(cellAt(fit, 0, 0), [0, 0])
    assert.deepEqual(cellAt(fit, WIDTH - 1, WIDTH - 1), [255, 255])
  })
})

describe("span", () => {
  // A cell of 2.7 pixels, which no whole number of pixels divides.
  const odd = viewGeometry(691, MAP)

  test("tiles: the run of one cell after another is where the next one starts", () => {
    assert.ok(Math.abs(odd.cell - Math.round(odd.cell)) > 0.05)
    for (let from = 0; from < 255; from++) {
      const [start, size] = span(odd, 0, from, 1)
      const [next] = span(odd, 0, from + 1, 1)
      assert.equal(start + size, next, `at ${from}`)
    }
  })

  test("is a run of cells as the cells together", () => {
    const [start, size] = span(odd, 0, 10, 40)
    assert.equal(start, span(odd, 0, 10, 1)[0])
    assert.equal(start + size, span(odd, 0, 49, 1).reduce((a, b) => a + b))
  })

  test("is at least a pixel, and starts before the canvas for a cell scrolled off it", () => {
    assert.ok(span(viewGeometry(100, MAP), 0, 3, 1)[1] >= 1)
    assert.ok(span(viewGeometry(WIDTH, MAP, 2, [50, 50]), 0, 40, 1)[0] < 0)
  })
})

describe("zooming and panning", () => {
  test("keep the cell under the anchor under it", () => {
    for (const anchor of [[384, 384], [0, 0], [700, 100], [123, 456]]) {
      let geo = viewGeometry(WIDTH, MAP, 1, [40, 60])
      const under = [geo.pan[0] + anchor[0] / geo.cell, geo.pan[1] + anchor[1] / geo.cell]
      const {zoom, pan} = zoomed(geo, 1, anchor)
      geo = viewGeometry(WIDTH, MAP, zoom, pan)
      assert.equal(geo.zoom, 2)
      assert.ok(Math.abs(geo.pan[0] + anchor[0] / geo.cell - under[0]) < 1e-9, String(anchor))
      assert.ok(Math.abs(geo.pan[1] + anchor[1] / geo.cell - under[1]) < 1e-9, String(anchor))
    }
  })

  test("stop at the ends of the steps", () => {
    assert.equal(zoomed(fit, -1).zoom, 0)
    assert.equal(zoomed(viewGeometry(WIDTH, MAP, ZOOMS.length - 1), 1).zoom, ZOOMS.length - 1)
  })

  test("pan the map with the drag: a drag to the right shows what is to the left", () => {
    const geo = viewGeometry(WIDTH, MAP, 2, [100, 100])
    assert.deepEqual(panned(geo, 60, -30), [100 - 60 / geo.cell, 100 + 30 / geo.cell])
    assert.deepEqual(viewGeometry(WIDTH, MAP, 2, panned(geo, 100_000, 100_000)).pan, [0, 0])
  })

  test("leave a click's reach at a cell of its own size when the cell is big, and wider when small", () => {
    assert.equal(pickRadius(viewGeometry(WIDTH, MAP, 3)), 0)
    assert.equal(pickRadius(fit), 2)
    assert.equal(pickRadius(viewGeometry(WIDTH, MAP, 1)), 1)
  })
})

describe("making ready", () => {
  test("works out the ground once, and the heat for each scene", () => {
    assert.equal(prepared.grid.length, MAP.width * MAP.height)
    const world = worldOf(flowing)
    assert.equal(world.scene, flowing)
    assert.equal(world.heatGrid.length, MAP.width * MAP.height)
    assert.equal(world.heatPalette.levels.length, 52)
    assert.equal(world.ground, prepared.ground)
  })

  test("has no heat to ready for a scene that has none", () => {
    const world = worldOf({...flowing, overlays: {...flowing.overlays, heat: null}})
    assert.equal(world.heat, null)
    assert.equal(world.heatGrid, null)
    assert.doesNotThrow(() => paint(world, fit, {...DEFAULT_OVERLAYS, heat: true}))
  })
})

describe("painting", () => {
  const water = flowing.overlays.water.colors
  const bed = groundData.reaches.flat().length

  test("begins with the canvas's scale and its background", () => {
    const ctx = paint(worldOf(flowing), fit)
    assert.equal(ctx.calls[0].op, "setTransform")
    assert.deepEqual(rects(ctx)[0].args, [0, 0, fit.width, fit.height])
    assert.equal(rects(ctx)[0].fillStyle, BACKGROUND)
  })

  test("draws the ground in runs, a rectangle for each run of one colour and not for each cell", () => {
    const ctx = paint(worldOf(flowing), fit, {water: false, heat: false, smoke: false})
    const ground = rects(ctx).filter((r) => r.fillStyle !== BACKGROUND && r.globalAlpha === 1)
    assert.ok(ground.length > 256)
    assert.ok(ground.length < MAP.width * MAP.height / 4, `${ground.length} rectangles`)
    const colours = new Set(Object.values(groundColors(groundData)))
    assert.ok(ground.filter((r) => colours.has(r.fillStyle)).length > ground.length * 0.9)
  })

  test("draws each bed cell of the river once, running or silent as its reach is", () => {
    for (const scene of [flowing, drying]) {
      const ctx = paint(worldOf(scene), fit, {water: true, heat: false, smoke: false})
      const wet = rects(ctx).filter((r) => r.fillStyle === water.flowing && r.globalAlpha === 1)
      const dry = rects(ctx).filter((r) => r.fillStyle === water.silent && r.globalAlpha === 1)
      const silent = scene.overlays.water.reaches.flatMap((reach, k) => (reach.silent ? groundData.reaches[k] : []))
      assert.equal(dry.length, silent.length)
      assert.equal(wet.length, bed - silent.length)
    }
  })

  test("shows the river drying: more of the bed is dry an hour and a half after the source fails", () => {
    const count = (scene) =>
      scene.overlays.water.reaches.filter((reach) => reach.silent).length
    assert.equal(count(flowing), 0)
    assert.ok(count(drying) > 4)
    const ctx = paint(worldOf(drying), fit, {water: true, heat: false, smoke: false})
    assert.ok(rects(ctx).some((r) => r.fillStyle === water.silent))
  })

  test("leaves the river's bed dry when the water overlay is off", () => {
    const ctx = paint(worldOf(flowing), fit, {water: false, heat: false, smoke: false})
    assert.equal(rects(ctx).filter((r) => r.fillStyle === water.flowing).length, 0)
  })

  test("hazes the banks of a reach that steams, under its bed", () => {
    const steaming = flowing.overlays.water.reaches.map((reach, k) => (reach.steaming ? groundData.reaches[k].length : 0))
    const ctx = paint(worldOf(flowing), fit, {water: true, heat: false, smoke: false})
    const haze = rects(ctx).filter((r) => r.fillStyle === water.steam)
    assert.equal(haze.length, steaming.reduce((a, b) => a + b, 0))
    assert.ok(haze.every((r) => r.globalAlpha < 0.5))
  })

  test("draws the heat only when it is on, over the whole map, translucent", () => {
    const world = worldOf(flowing)
    const translucent = (r) => r.globalAlpha === 0.8
    assert.equal(rects(paint(world, fit)).filter(translucent).length, 0)

    const ctx = paint(world, fit, {...DEFAULT_OVERLAYS, heat: true})
    const heat = rects(ctx).filter(translucent)
    assert.ok(heat.length > 256)
    const colours = new Set([...world.heatPalette.levels, ...Object.values(world.heatPalette.backgrounds)])
    assert.ok(heat.every((r) => colours.has(r.fillStyle)))
    assert.ok(heat.some((r) => r.fillStyle === world.heatPalette.backgrounds.grass))
  })

  test("draws a puff of smoke as a disc, for each that is in the window, and none when it is off", () => {
    const puffs = flowing.overlays.smoke.puffs
    assert.ok(puffs.length > 4)
    const world = worldOf(flowing)

    const on = paint(world, fit, {...DEFAULT_OVERLAYS, smoke: true})
    assert.equal(ops(on, "arc").filter((call) => call.fillStyle === flowing.overlays.smoke.color).length >= puffs.length, true)
    const discs = ops(on, "fill").length
    assert.equal(discs, puffs.length)

    assert.equal(ops(paint(world, fit, {...DEFAULT_OVERLAYS, smoke: false}), "fill").length, 0)
  })

  test("makes a puff as wide as the square root of its mass, up to a few cells", () => {
    assert.ok(puffRadius(0.01) < puffRadius(0.2))
    assert.ok(puffRadius(0.2) < puffRadius(2))
    assert.equal(puffRadius(0.25), 3)
    assert.equal(puffRadius(1), 5)
    assert.equal(puffRadius(1e9), 6)
  })

  test("draws things as markers while the cell is too small to read, each in its glyph's colour", () => {
    assert.ok(fit.cell < GLYPH_FROM)
    const ctx = paint(worldOf(flowing), fit, {water: false, heat: false, smoke: false})
    assert.equal(ops(ctx, "fillText").length, 0)
    for (const thing of flowing.things) {
      assert.ok(rects(ctx).some((r) => r.fillStyle === thing.glyph.color && r.args[2] === r.args[3] && r.args[2] >= 4), thing.id)
    }
  })

  test("draws things as their glyphs when the cell is big enough, those that are in the window", () => {
    const mira = flowing.things.find((thing) => thing.id === "mira-vale")
    const geo = viewGeometry(WIDTH, MAP, 3, [mira.cell[0] - 10, mira.cell[1] - 10])
    assert.ok(geo.cell >= GLYPH_FROM)
    const ctx = paint(worldOf(flowing), geo, {water: false, heat: false, smoke: false})
    const written = ops(ctx, "fillText")
    assert.ok(written.some((call) => call.args[0] === mira.glyph.char && call.fillStyle === mira.glyph.color))
    const inside = flowing.things.filter((thing) => {
      const [x, y] = thing.cell
      const {x: columns, y: rows} = visible(geo)
      return x >= columns[0] && x < columns[1] && y >= rows[0] && y < rows[1]
    })
    assert.equal(written.length, inside.length)
  })

  test("changes from markers to glyphs at the cell size that can be read, and not before", () => {
    const options = {water: false, heat: false, smoke: false}
    const at = (cell) => viewGeometry(MAP.width * cell, MAP, 0)
    assert.equal(at(GLYPH_FROM).cell, GLYPH_FROM)
    assert.ok(ops(paint(worldOf(flowing), at(GLYPH_FROM), options), "fillText").length > 0)
    assert.equal(ops(paint(worldOf(flowing), at(GLYPH_FROM - 1), options), "fillText").length, 0)
  })

  test("rings a body somebody holds, and no other thing", () => {
    const ctx = paint(worldOf(flowing), fit, {water: false, heat: false, smoke: false})
    const held = flowing.things.filter((thing) => thing.holder)
    assert.ok(held.length >= 1)
    assert.equal(ops(ctx, "stroke").length, held.length)
  })

  test("draws only the part of the map that is in the window, so that a zoom is cheap", () => {
    const world = worldOf(flowing)
    const all = rects(paint(world, fit, {water: false, heat: false, smoke: false})).length
    const corner = rects(paint(world, viewGeometry(WIDTH, MAP, 3, [0, 0]), {water: false, heat: false, smoke: false})).length
    assert.ok(corner < all / 10, `${corner} against ${all}`)
  })

  test("dims the valley by the light, and not at all at noon", () => {
    const world = worldOf({...flowing, light: 0})
    const ctx = paint(world, fit, {water: false, heat: false, smoke: false})
    const dark = rects(ctx).find((r) => r.fillStyle === "#000000")
    assert.ok(dark)
    assert.ok(Math.abs(dark.globalAlpha - (1 - brightness(0))) < 1e-9)

    const noon = paint(worldOf({...flowing, light: 1}), fit, {water: false, heat: false, smoke: false})
    assert.equal(rects(noon).filter((r) => r.fillStyle === "#000000").length, 0)
  })

  test("leaves the overlays undimmed too: the heat and the river are drawn after the dark", () => {
    const night = worldOf({...flowing, light: 0})
    const ctx = paint(night, fit, {water: true, heat: true, smoke: false})
    const darkAt = ctx.calls.findIndex((call) => call.op === "fillRect" && call.fillStyle === "#000000")
    const after = (match) => ctx.calls.findIndex((call, i) => i > darkAt && call.op === "fillRect" && match(call))
    assert.ok(darkAt > 0)
    assert.ok(after((call) => call.globalAlpha === 0.8) > darkAt, "the heat")
    assert.ok(after((call) => call.fillStyle === water.flowing) > darkAt, "the river")
  })

  test("leaves things undimmed: they are drawn after the dark", () => {
    const ctx = paint(worldOf({...flowing, light: 0}), fit, {water: false, heat: false, smoke: false})
    const darkAt = ctx.calls.findIndex((call) => call.op === "fillRect" && call.fillStyle === "#000000")
    const thing = flowing.things[0]
    const markerAt = ctx.calls.findIndex((call, i) => i > darkAt && call.op === "fillRect" && call.fillStyle === thing.glyph.color)
    assert.ok(darkAt > 0 && markerAt > darkAt)
  })
})

describe("the mirror", () => {
  test("says what was drawn, as a test reads it", () => {
    const mirror = mirrorWorld(worldOf(flowing), fit, DEFAULT_OVERLAYS)

    assert.equal(mirror.drawnGround, "256x256")
    assert.equal(mirror.drawnZoom, "0")
    assert.equal(mirror.drawnCellPixels, "3")
    assert.equal(mirror.drawnPan, "0,0")
    assert.equal(mirror.drawnView, "256,256")
    assert.equal(mirror.drawnOverlays, "water,smoke")
    assert.equal(mirror.drawnTime, String(flowing.time))
    assert.equal(mirror.drawnLight, String(flowing.light))
    assert.equal(mirror.drawnThings, flowing.things.map((thing) => thing.id).sort().join(","))
    assert.equal(mirror.drawnReaches, "23")
    assert.equal(mirror.drawnSilent, "0")
    assert.equal(mirror.drawnPuffs, String(flowing.overlays.smoke.puffs.length))
    assert.ok(Number(mirror.drawnHeatCells) > 3000)
  })

  test("follows the scene, the zoom and the switches", () => {
    const geo = viewGeometry(WIDTH, MAP, 2, [10, 20])
    const on = {water: false, heat: true, smoke: false}
    const mirror = mirrorWorld(worldOf(drying), geo, on)

    assert.equal(mirror.drawnZoom, "2")
    assert.equal(mirror.drawnPan, "10,20")
    assert.equal(mirror.drawnOverlays, "heat")
    assert.equal(mirror.drawnSilent, String(drying.overlays.water.reaches.filter((reach) => reach.silent).length))
    assert.ok(Number(mirror.drawnSilent) > 4)
  })

  test("lists the overlays there are, in order", () => {
    assert.deepEqual(OVERLAYS, ["water", "heat", "smoke"])
  })
})
