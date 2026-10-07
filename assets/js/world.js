// How a spectator's scene is drawn, apart from the canvas that does it.
//
// A spectator sees the whole valley. Its ground (Avwe.WorldGround.to_map/1)
// comes once and never changes; its scene (Avwe.WorldScene.to_map/1) comes with
// every step that changes something, with the river, the heat and the smoke as
// overlays and everything in the valley as things. This module turns them into
// where each rectangle goes and in what colour, and decides nothing about the
// game: it draws what it is given, in the colours the server's legend and
// overlays give. The functions are plain, so Node tests them without a browser
// (`npm test`); the paint functions take any object with a canvas context's
// methods.
import {BACKGROUND, brightness, decodeRow, ordered, shade} from "./draw.js"

// The zoom steps, each a multiple of the size at which the whole map fits.
export const ZOOMS = [1, 2, 4, 8]

// The overlays a viewer can switch, and which are on to begin with: the river
// and the smoke, and not the heat, which colours the whole map.
export const OVERLAYS = ["water", "heat", "smoke"]
export const DEFAULT_OVERLAYS = {water: true, heat: false, smoke: true}

// From what size of cell a thing is drawn as its glyph; below it, a marker.
export const GLYPH_FROM = 10

// How dark the ground is drawn under what lies over it, so that overlays and
// things stand out.
const GROUND_SHADE = 0.6

// How opaque each overlay is over the ground.
const HEAT_ALPHA = 0.8
const STEAM_ALPHA = 0.28

// The levels of the heat overlay, as the server writes them (Avwe.Overlays).
const LEVELS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

const STONE = "t".charCodeAt(0)

const clamp = (value, low, high) => Math.max(low, Math.min(high, value))

// The ground

// The letters of the ground, a byte for each cell: `grid[y * width + x]` is the
// character code of the cell's letter.
export function groundGrid(ground) {
  const grid = new Uint8Array(ground.width * ground.height)
  ground.rows.forEach((row, y) => {
    decodeRow(row).forEach((letter, x) => {
      grid[y * ground.width + x] = letter.charCodeAt(0)
    })
  })
  return grid
}

// The kind a ground letter stands for, from the ground's own letters.
export const GROUND_KINDS = {
  g: "grass",
  s: "silt",
  c: "clay",
  t: "stone",
  r: "reeds",
  b: "channel_bed",
}

// What the ground is drawn in: each kind's colour from the legend, darkened.
export function groundColors(ground) {
  const colors = {}
  for (const [letter, kind] of Object.entries(GROUND_KINDS)) {
    const color = ground.legend[kind]?.glyph.color
    if (color) colors[letter] = shade(color, GROUND_SHADE)
  }
  return colors
}

// The heat

// The level of each cell of the heat overlay, or -1 for a cell that is not
// stored: `grid[y * width + x]`.
export function heatGrid(heat, width, height) {
  const grid = new Int8Array(width * height).fill(-1)
  heat.rows.slice(0, height).forEach((row, y) => {
    decodeRow(row).forEach((symbol, x) => {
      grid[y * width + x] = symbol === "." ? -1 : LEVELS.indexOf(symbol)
    })
  })
  return grid
}

// The temperature a level stands for, in the overlay's unit.
export function heatTemp(heat, level) {
  return heat.base + heat.step * level
}

function hexChannels(hex) {
  return [1, 3, 5].map((at) => parseInt(hex.slice(at, at + 2), 16))
}

function hexColor(channels) {
  return "#" + channels.map((c) => Math.round(c).toString(16).padStart(2, "0")).join("")
}

// A colour on a ramp (`[{at, color}]`, coldest first) at a value: the ends for
// what is beyond them, and a mix of the two nearest stops between.
export function rampColor(ramp, value) {
  if (value <= ramp[0].at) return ramp[0].color
  const last = ramp[ramp.length - 1]
  if (value >= last.at) return last.color
  const upper = ramp.findIndex((stop) => stop.at >= value)
  const [low, high] = [ramp[upper - 1], ramp[upper]]
  const t = (value - low.at) / (high.at - low.at)
  const [a, b] = [hexChannels(low.color), hexChannels(high.color)]
  return hexColor(a.map((from, i) => from + (b[i] - from) * t))
}

// The colour of each level, and of the two backgrounds.
export function heatColors(heat) {
  const levels = [...LEVELS].map((_, level) => rampColor(heat.ramp, heatTemp(heat, level)))
  const backgrounds = {}
  for (const [ground, temp] of Object.entries(heat.backgrounds)) {
    if (temp !== null) backgrounds[ground] = rampColor(heat.ramp, temp)
  }
  return {levels, backgrounds}
}

// Making ready

// What is worked out once for a ground, and once more for each scene, so that a
// frame only draws.
export function prepareGround(ground) {
  return {ground, grid: groundGrid(ground), colors: groundColors(ground)}
}

export function prepareScene(prepared, scene) {
  const {width, height} = prepared.ground
  const heat = scene.overlays.heat
  return {
    ...prepared,
    scene,
    heat,
    heatGrid: heat ? heatGrid(heat, width, height) : null,
    heatPalette: heat ? heatColors(heat) : null,
  }
}

// Where things are

// The window on the map: how big a cell is, what part of the map is shown, and
// where. Zoom 0 fits the whole map in the width; each step doubles the cell,
// and the window is panned to the cell at its top left, kept on the map.
export function viewGeometry(width, map, zoom = 0, pan = [0, 0]) {
  const level = clamp(zoom, 0, ZOOMS.length - 1)
  const cell = (width / map.width) * ZOOMS[level]
  const height = Math.round((width * map.height) / map.width)
  const view = [width / cell, height / cell]
  return {
    cell,
    zoom: level,
    width,
    height,
    view,
    map: [map.width, map.height],
    pan: [
      clamp(pan[0], 0, Math.max(0, map.width - view[0])),
      clamp(pan[1], 0, Math.max(0, map.height - view[1])),
    ],
  }
}

// Where a cell's top-left corner is, in pixels (it may be off the canvas).
export function pixelOf(geo, [x, y]) {
  return [(x - geo.pan[0]) * geo.cell, (y - geo.pan[1]) * geo.cell]
}

// Which cell a pixel is in, or null for a pixel outside the canvas or the map.
export function cellAt(geo, px, py) {
  if (px < 0 || py < 0 || px >= geo.width || py >= geo.height) return null
  const x = Math.floor(geo.pan[0] + px / geo.cell)
  const y = Math.floor(geo.pan[1] + py / geo.cell)
  return x < geo.map[0] && y < geo.map[1] ? [x, y] : null
}

// The pixels `count` cells take from cell `from` along one axis, as [start,
// size]. Edges are rounded where they fall, so neighbouring runs meet with no
// seam between them.
export function span(geo, axis, from, count) {
  const start = Math.round((from - geo.pan[axis]) * geo.cell)
  const end = Math.round((from + count - geo.pan[axis]) * geo.cell)
  return [start, Math.max(1, end - start)]
}

// The columns and rows that are in the window, as half-open ranges.
export function visible(geo) {
  const x0 = Math.max(0, Math.floor(geo.pan[0]))
  const y0 = Math.max(0, Math.floor(geo.pan[1]))
  return {
    x: [x0, Math.min(geo.map[0], Math.ceil(geo.pan[0] + geo.view[0]))],
    y: [y0, Math.min(geo.map[1], Math.ceil(geo.pan[1] + geo.view[1]))],
  }
}

// The window after a zoom step (+1 in, -1 out), keeping the cell under the
// anchor (a pixel, by default the middle) where it is.
export function zoomed(geo, step, anchor = [geo.width / 2, geo.height / 2]) {
  const zoom = clamp(geo.zoom + step, 0, ZOOMS.length - 1)
  const under = [geo.pan[0] + anchor[0] / geo.cell, geo.pan[1] + anchor[1] / geo.cell]
  const cell = (geo.width / geo.map[0]) * ZOOMS[zoom]
  return {zoom, pan: [under[0] - anchor[0] / cell, under[1] - anchor[1] / cell]}
}

// The window after the map is dragged by a number of pixels.
export function panned(geo, dx, dy) {
  return [geo.pan[0] - dx / geo.cell, geo.pan[1] - dy / geo.cell]
}

// How far, in cells, a click may miss a thing and still mean it: about eight
// pixels, which is none at a big cell and a couple at the map's own size.
export function pickRadius(geo, pixels = 8) {
  return Math.max(0, Math.min(4, Math.ceil(pixels / geo.cell) - 1))
}

// Painting

// Fills what `colorAt(x, y)` says, over the cells in the window, a run of one
// colour a rectangle. A colour of null leaves the cell as it is.
function paintCells(ctx, geo, colorAt) {
  const {x: columns, y: rows} = visible(geo)
  if (columns[0] >= columns[1]) return
  for (let y = rows[0]; y < rows[1]; y++) {
    const [top, height] = span(geo, 1, y, 1)
    let from = columns[0]
    let color = colorAt(from, y)
    for (let x = columns[0] + 1; x <= columns[1]; x++) {
      const next = x < columns[1] ? colorAt(x, y) : undefined
      if (next === color) continue
      if (color) {
        const [left, width] = span(geo, 0, from, x - from)
        ctx.fillStyle = color
        ctx.fillRect(left, top, width, height)
      }
      from = x
      color = next
    }
  }
}

// The ground, with the river's bed dry everywhere: whether it runs is the water
// overlay's to show.
function paintGround(ctx, world, geo) {
  const {grid, colors, ground} = world
  paintCells(ctx, geo, (x, y) => colors[String.fromCharCode(grid[y * ground.width + x])] ?? null)
}

// The colour of a cell in the heat overlay: its own level's, if the server
// stores it, and otherwise its ground's background: the open stone's, or the
// open grass's for the rest. Null when the world gave no such background.
export function heatColorAt(world, x, y) {
  const at = y * world.ground.width + x
  const level = world.heatGrid[at]
  if (level >= 0) return world.heatPalette.levels[level]
  const {stone, grass} = world.heatPalette.backgrounds
  return (world.grid[at] === STONE ? stone : grass) ?? null
}

function paintHeat(ctx, world, geo) {
  ctx.globalAlpha = HEAT_ALPHA
  paintCells(ctx, geo, (x, y) => heatColorAt(world, x, y))
  ctx.globalAlpha = 1
}

// The river by reach: a pale haze on the banks of one that steams, under its
// bed, which is the colour of running water or of the dry bed.
function paintWater(ctx, world, geo) {
  const {colors, reaches: states} = world.scene.overlays.water
  const {ground} = world

  ctx.globalAlpha = STEAM_ALPHA
  ctx.fillStyle = colors.steam
  states.forEach((reach, k) => {
    if (!reach.steaming) return
    for (const [x, y] of ground.reaches[k] ?? []) {
      const [left, width] = span(geo, 0, x - 1, 3)
      const [top, height] = span(geo, 1, y - 1, 3)
      ctx.fillRect(left, top, width, height)
    }
  })
  ctx.globalAlpha = 1

  states.forEach((reach, k) => {
    ctx.fillStyle = reach.silent ? colors.silent : colors.flowing
    for (const [x, y] of ground.reaches[k] ?? []) {
      const [left, width] = span(geo, 0, x, 1)
      const [top, height] = span(geo, 1, y, 1)
      ctx.fillRect(left, top, width, height)
    }
  })
}

// The dark: the ground dims at night, and what is drawn over it does not. The
// overlays are data and the things are what is looked for, and neither is made
// harder to read by the dark.
function paintLight(ctx, world, geo) {
  const dark = 1 - brightness(world.scene.light)
  if (dark <= 0) return
  ctx.globalAlpha = dark
  ctx.fillStyle = "#000000"
  ctx.fillRect(0, 0, geo.width, geo.height)
  ctx.globalAlpha = 1
}

// A puff is a disc as wide as its mass: a few cells across.
export function puffRadius(grams) {
  return Math.min(6, 1 + 4 * Math.sqrt(grams))
}

function paintSmoke(ctx, world, geo) {
  const smoke = world.scene.overlays.smoke
  ctx.fillStyle = smoke.color
  for (const [x, y, grams] of smoke.puffs) {
    const [px, py] = pixelOf(geo, [x + 0.5, y + 0.5])
    const radius = puffRadius(grams) * geo.cell
    if (px + radius < 0 || py + radius < 0 || px - radius > geo.width || py - radius > geo.height) continue
    ctx.globalAlpha = 0.1 + Math.min(0.35, grams)
    ctx.beginPath()
    ctx.arc(px, py, radius, 0, 2 * Math.PI)
    ctx.fill()
  }
  ctx.globalAlpha = 1
}

// A thing is its glyph when the cell is big enough to read one, and a marker
// when it is not. A held body has a ring.
function paintThings(ctx, world, geo) {
  const {x: columns, y: rows} = visible(geo)
  const glyphs = geo.cell >= GLYPH_FROM
  if (glyphs) {
    ctx.font = `${Math.floor(geo.cell * 0.92)}px ui-monospace, "SF Mono", Menlo, Consolas, monospace`
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
  }

  for (const thing of ordered(world.scene.things)) {
    const [x, y] = thing.cell
    if (x < columns[0] || x >= columns[1] || y < rows[0] || y >= rows[1]) continue
    const [px, py] = pixelOf(geo, thing.cell)
    const [cx, cy] = [px + geo.cell / 2, py + geo.cell / 2]
    ctx.fillStyle = thing.glyph.color
    if (glyphs) {
      ctx.fillText(thing.glyph.char, cx, cy)
    } else {
      const size = Math.max(4, Math.round(geo.cell * 1.4))
      ctx.fillRect(Math.round(cx - size / 2), Math.round(cy - size / 2), size, size)
    }
    if (thing.holder) {
      ctx.strokeStyle = "#ffffff"
      ctx.lineWidth = 1.5
      ctx.beginPath()
      ctx.arc(cx, cy, Math.max(5, geo.cell * 0.9), 0, 2 * Math.PI)
      ctx.stroke()
    }
  }
}

// Draws a prepared scene on a canvas context, in the window `geo` says, with
// the overlays that are on (`on`, by name).
export function paintWorld(ctx, world, geo, on = DEFAULT_OVERLAYS, pixelRatio = 1) {
  ctx.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0)
  ctx.fillStyle = BACKGROUND
  ctx.fillRect(0, 0, geo.width, geo.height)
  paintGround(ctx, world, geo)
  paintLight(ctx, world, geo)
  if (on.heat && world.heat) paintHeat(ctx, world, geo)
  if (on.water) paintWater(ctx, world, geo)
  if (on.smoke) paintSmoke(ctx, world, geo)
  paintThings(ctx, world, geo)
}

// What the hook writes on the canvas once it has drawn, as data attributes, so
// that a test reads what was drawn and not the pixels.
export function mirrorWorld(world, geo, on) {
  const {scene, heat, ground} = world
  const tenth = (n) => String(Math.round(n * 10) / 10)
  return {
    drawnGround: `${ground.width}x${ground.height}`,
    drawnZoom: String(geo.zoom),
    drawnCellPixels: tenth(geo.cell),
    drawnPan: geo.pan.map(tenth).join(","),
    drawnView: geo.view.map(tenth).join(","),
    drawnOverlays: OVERLAYS.filter((name) => on[name]).join(","),
    drawnTime: String(scene.time),
    drawnLight: String(scene.light),
    drawnThings: scene.things.map((thing) => thing.id).sort().join(","),
    drawnReaches: String(scene.overlays.water.reaches.length),
    drawnSilent: String(scene.overlays.water.reaches.filter((reach) => reach.silent).length),
    drawnHeatCells: String(heat ? world.heatGrid.filter((level) => level >= 0).length : 0),
    drawnPuffs: String(scene.overlays.smoke.puffs.length),
  }
}
