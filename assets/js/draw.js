// How a scene is drawn, apart from the canvas that does it.
//
// A scene (Avwe.Scene.to_map/1) says what a body can see: a window of ground
// as run-length-coded rows, and the things in it. This module turns that into
// where each glyph goes and in what colour. It decides nothing about the game:
// it draws what it is given, and a cell that is blank in the scene is blank
// here. The functions are plain, so Node tests them without a browser (`npm
// test`); `paint` takes any object with a canvas context's methods.

export const BACKGROUND = "#0e0c09"

// The letters of a row, as the server writes them (Avwe.Scene).
export const KINDS = {
  g: "grass",
  s: "silt",
  c: "clay",
  t: "stone",
  r: "reeds",
  b: "channel_bed",
  w: "water",
}

const BLANK = "."

// What lights itself: it is not dimmed by the dark.
const LIGHT_SOURCES = new Set(["glow", "hearth_burning"])

// Under what: a place lies on the ground, a body stands on a place.
const LAYERS = {place: 0, hearth: 1, hearth_burning: 1, smoke: 2, glow: 2, body: 3}

const DARKEST = 0.35
const FOGGIEST = 0.45

// "g3s2.4" is three grass, two silt and four cells that are not seen.
export function decodeRow(row) {
  const letters = []
  for (const [, letter, count] of row.matchAll(/([a-z.])(\d+)/g)) {
    for (let n = 0; n < Number(count); n++) letters.push(letter)
  }
  return letters
}

// How many cells across the near view shows, with the viewer in the middle.
export const NEAR = 41

// The part of the window that is shown: all of it, or, when it is wider than
// `limit`, the cells around the viewer. The size is odd, so the viewer is in
// the middle.
export function viewport(scene, limit = Infinity) {
  if (scene.size <= limit) return {origin: scene.origin, size: scene.size}
  const size = limit % 2 === 0 ? limit + 1 : limit
  const half = (size - 1) / 2
  return {origin: [scene.center[0] - half, scene.center[1] - half], size}
}

// How big a cell is, and where the view sits. The near view (the default) is
// the cells close around the viewer, big enough to read; the far one is the
// whole of what is in sight, at the size that fits. Either is fitted to the
// width there is, between a cell too small to read and one too big to need.
export function geometry(scene, width, {min = 4, max = 40, zoom = "near", near = NEAR} = {}) {
  const view = viewport(scene, zoom === "near" ? near : Infinity)
  const cell = Math.max(min, Math.min(max, Math.floor(width / view.size)))
  const side = cell * view.size
  return {cell, size: view.size, origin: view.origin, width: side, height: side, zoom}
}

// Where a cell is, as the top-left corner of its square, in pixels.
export function cellRect(geo, [x, y]) {
  return {
    x: (x - geo.origin[0]) * geo.cell,
    y: (y - geo.origin[1]) * geo.cell,
    size: geo.cell,
  }
}

// Whether a cell is in the view.
export function inside(geo, [x, y]) {
  return (
    x >= geo.origin[0] && x < geo.origin[0] + geo.size && y >= geo.origin[1] && y < geo.origin[1] + geo.size
  )
}

// Which cell a pixel is in, or null for a pixel outside the window.
export function cellAtPixel(geo, px, py) {
  if (px < 0 || py < 0 || px >= geo.width || py >= geo.height) return null
  return [geo.origin[0] + Math.floor(px / geo.cell), geo.origin[1] + Math.floor(py / geo.cell)]
}

// How bright the day is: full at noon, dim but never black at night, since
// what a body can see it sees.
export function brightness(light) {
  const level = Math.max(0, Math.min(1, light))
  return DARKEST + (1 - DARKEST) * level
}

// How much the far edge of sight fades: none at the centre, most at the rim,
// and no more beyond it.
export function fog(distance, radius) {
  const ratio = radius > 0 ? Math.min(1, distance / radius) : 0
  return 1 - (1 - FOGGIEST) * ratio * ratio
}

// A colour made darker by a factor from 0 to 1.
export function shade(hex, factor) {
  const level = Math.max(0, Math.min(1, factor))
  const channels = [1, 3, 5].map((at) => Math.round(parseInt(hex.slice(at, at + 2), 16) * level))
  return "#" + channels.map((c) => c.toString(16).padStart(2, "0")).join("")
}

export function distance([ax, ay], [bx, by]) {
  return Math.hypot(ax - bx, ay - by)
}

// How much a glyph of a kind, at a cell, is dimmed.
export function factor(scene, kind, cell) {
  if (LIGHT_SOURCES.has(kind)) return 1
  return brightness(scene.light) * fog(distance(cell, scene.center), scene.radius)
}

// The ground the scene shows: each cell that is not blank, with the glyph the
// legend gives its kind. A cell of a kind the legend does not know is left out.
export function ground(scene) {
  const cells = []
  scene.rows?.forEach((row, dy) => {
    decodeRow(row).forEach((letter, dx) => {
      const kind = KINDS[letter]
      const glyph = scene.legend[kind]?.glyph
      if (letter !== BLANK && glyph) {
        cells.push({cell: [scene.origin[0] + dx, scene.origin[1] + dy], kind, glyph})
      }
    })
  })
  return cells
}

// The things in the order they are drawn, each over what lies under it.
export function ordered(things) {
  const layer = (thing) => LAYERS[thing.kind] ?? 0
  return [...things].sort((a, b) => layer(a) - layer(b) || a.id.localeCompare(b.id))
}

// Draws the scene on a canvas context: the ground, the things, and the viewer
// last, those of them that are in the view. `pixelRatio` is the screen's, so that glyphs stay sharp on one that
// is dense.
export function paint(ctx, scene, geo, pixelRatio = 1) {
  ctx.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0)
  ctx.fillStyle = BACKGROUND
  ctx.fillRect(0, 0, geo.width, geo.height)
  ctx.font = `${Math.max(6, Math.floor(geo.cell * 0.92))}px ui-monospace, "SF Mono", Menlo, Consolas, monospace`
  ctx.textAlign = "center"
  ctx.textBaseline = "middle"

  const put = (kind, cell, glyph) => {
    if (!inside(geo, cell)) return
    const rect = cellRect(geo, cell)
    ctx.fillStyle = shade(glyph.color, factor(scene, kind, cell))
    ctx.fillText(glyph.char, rect.x + rect.size / 2, rect.y + rect.size / 2)
  }

  for (const {cell, kind, glyph} of ground(scene)) put(kind, cell, glyph)
  for (const thing of ordered(scene.things)) put(thing.kind, thing.cell, thing.glyph)
  put("body", scene.center, scene.you.glyph)
}

// What the hook writes on the canvas once it has drawn, as data attributes,
// so that a test reads what was drawn and not the pixels.
export function mirror(scene, geo) {
  return {
    drawnZoom: geo.zoom,
    drawnShown: String(geo.size),
    drawnCellPixels: String(geo.cell),
    drawnTime: String(scene.time),
    drawnCenter: scene.center.join(","),
    drawnRadius: String(scene.radius),
    drawnLight: String(scene.light),
    drawnCells: String(ground(scene).length),
    drawnThings: scene.things.map((thing) => thing.id).sort().join(","),
  }
}
