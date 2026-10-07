// The hooks of the pages: the one script's jobs. They hold no game logic: the
// server decides what a click means and whether it is allowed.
import {cellAtPixel, geometry, mirror, paint} from "./draw.js"
import {
  cellAt,
  DEFAULT_OVERLAYS,
  mirrorWorld,
  paintWorld,
  panned,
  pickRadius,
  prepareGround,
  prepareScene,
  viewGeometry,
  zoomed,
} from "./world.js"

// Draws the scene the server puts on the canvas (`data-scene`), and says which
// cell a click fell on.
export const SceneCanvas = {
  mounted() {
    this.scene = null
    this.geo = null
    this.zoom = "near"
    this.onClick = (event) => {
      if (!this.geo) return
      // The canvas has a border, which is not part of what is drawn.
      const box = this.el.getBoundingClientRect()
      const x = event.clientX - box.left - this.el.clientLeft
      const y = event.clientY - box.top - this.el.clientTop
      const cell = cellAtPixel(this.geo, x, y)
      if (cell) this.pushEvent("cell", {x: cell[0], y: cell[1]})
    }
    this.el.addEventListener("click", this.onClick)
    // The button beside the map asks for the wider view, and back.
    this.onZoom = () => {
      this.zoom = this.zoom === "near" ? "far" : "near"
      this.draw()
    }
    this.el.addEventListener("map:zoom", this.onZoom)
    this.observer = new ResizeObserver(() => this.draw())
    this.observer.observe(this.el.parentElement)
    this.read()
  },

  updated() {
    this.read()
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("map:zoom", this.onZoom)
    this.observer.disconnect()
  },

  read() {
    const raw = this.el.dataset.scene
    if (!raw) return
    try {
      this.scene = JSON.parse(raw)
    } catch (_error) {
      return
    }
    this.draw()
  },

  draw() {
    if (!this.scene) return
    const ratio = window.devicePixelRatio || 1
    this.geo = geometry(this.scene, this.el.parentElement.clientWidth, {zoom: this.zoom})
    this.el.width = Math.round(this.geo.width * ratio)
    this.el.height = Math.round(this.geo.height * ratio)
    this.el.style.width = `${this.geo.width}px`
    this.el.style.height = `${this.geo.height}px`
    paint(this.el.getContext("2d"), this.scene, this.geo, ratio)
    Object.assign(this.el.dataset, mirror(this.scene, this.geo))
  },
}

// How far a pointer may move and still have been a click, in pixels.
const CLICK_SLOP = 4

// How soon after one wheel step the next may count: a trackpad sends dozens.
const WHEEL_EVERY_MS = 150

// Draws the whole valley the server puts on the canvas: its ground (`data-ground`,
// which comes once) and its scene (`data-scene`, which comes with each change). The
// zoom, the pan and which overlays are on are the viewer's, and the server never
// hears of them; a click that is not a drag says which cell it fell on, and how
// far it may have missed, and the server says what is there.
export const WorldCanvas = {
  mounted() {
    this.on = {...DEFAULT_OVERLAYS}
    this.zoom = 0
    this.pan = [0, 0]
    this.prepared = null
    this.world = null
    this.geo = null
    this.rawGround = null
    this.rawScene = null
    this.drag = null
    this.lastWheel = 0

    this.listeners = {
      pointerdown: (event) => this.press(event),
      pointermove: (event) => this.move(event),
      pointerup: (event) => this.release(event),
      pointercancel: () => (this.drag = null),
      wheel: (event) => this.wheel(event),
      "map:zoom": (event) => this.zoomBy(event.detail.step),
      "map:fit": () => {
        this.zoom = 0
        this.pan = [0, 0]
        this.draw()
      },
      "map:overlay": (event) => {
        this.on[event.detail.overlay] = !this.on[event.detail.overlay]
        this.draw()
      },
    }
    for (const [name, listener] of Object.entries(this.listeners)) {
      this.el.addEventListener(name, listener, name === "wheel" ? {passive: false} : undefined)
    }
    this.observer = new ResizeObserver(() => this.draw())
    this.observer.observe(this.el.parentElement)
    this.read()
  },

  updated() {
    this.read()
  },

  destroyed() {
    for (const [name, listener] of Object.entries(this.listeners)) {
      this.el.removeEventListener(name, listener)
    }
    this.observer.disconnect()
  },

  // A pixel of the canvas, which has a border that is not part of what is drawn.
  local(event) {
    const box = this.el.getBoundingClientRect()
    return [event.clientX - box.left - this.el.clientLeft, event.clientY - box.top - this.el.clientTop]
  },

  press(event) {
    if (event.button !== 0 || !this.geo) return
    const at = this.local(event)
    this.drag = {start: at, last: at, moved: false}
    this.el.setPointerCapture?.(event.pointerId)
  },

  move(event) {
    if (!this.drag || !this.geo) return
    const at = this.local(event)
    const {start, last} = this.drag
    if (Math.hypot(at[0] - start[0], at[1] - start[1]) > CLICK_SLOP) this.drag.moved = true
    if (this.drag.moved) {
      this.pan = panned(this.geo, at[0] - last[0], at[1] - last[1])
      this.draw()
    }
    this.drag.last = at
  },

  release(event) {
    const drag = this.drag
    this.drag = null
    if (!drag || drag.moved || !this.geo) return
    const cell = cellAt(this.geo, ...this.local(event))
    if (cell) this.pushEvent("cell", {x: cell[0], y: cell[1], r: pickRadius(this.geo)})
  },

  wheel(event) {
    event.preventDefault()
    if (event.timeStamp - this.lastWheel < WHEEL_EVERY_MS || !this.geo) return
    this.lastWheel = event.timeStamp
    this.zoomBy(event.deltaY < 0 ? 1 : -1, this.local(event))
  },

  zoomBy(step, anchor) {
    if (!this.geo) return
    const {zoom, pan} = zoomed(this.geo, step, anchor)
    this.zoom = zoom
    this.pan = pan
    this.draw()
  },

  // Reads what the server gave the canvas, when it has changed: the ground once,
  // and each scene as it comes.
  read() {
    try {
      const ground = this.el.dataset.ground
      if (ground && ground !== this.rawGround) {
        this.prepared = prepareGround(JSON.parse(ground))
        this.rawGround = ground
        this.rawScene = null
      }
      const scene = this.el.dataset.scene
      if (this.prepared && scene && scene !== this.rawScene) {
        this.world = prepareScene(this.prepared, JSON.parse(scene))
        this.rawScene = scene
      }
    } catch (_error) {
      return
    }
    this.draw()
  },

  draw() {
    const width = this.el.parentElement.clientWidth
    if (!this.world || width === 0) return
    const ratio = window.devicePixelRatio || 1
    this.geo = viewGeometry(width, this.prepared.ground, this.zoom, this.pan)
    this.pan = this.geo.pan
    this.el.width = Math.round(this.geo.width * ratio)
    this.el.height = Math.round(this.geo.height * ratio)
    this.el.style.width = `${this.geo.width}px`
    this.el.style.height = `${this.geo.height}px`
    paintWorld(this.el.getContext("2d"), this.world, this.geo, this.on, ratio)
    Object.assign(this.el.dataset, mirrorWorld(this.world, this.geo, this.on))
  },
}

// Keeps the log scrolled to its newest line, unless the player has scrolled up
// to read an older one.
export const LogScroll = {
  mounted() {
    this.following = true
    this.el.addEventListener("scroll", () => {
      this.following = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 24
    })
    this.follow()
  },

  updated() {
    if (this.following) this.follow()
  },

  follow() {
    this.el.scrollTop = this.el.scrollHeight
  },
}

// Empties the command line once its line is sent.
export const CommandLine = {
  mounted() {
    this.el.addEventListener("submit", () => setTimeout(() => this.el.reset(), 0))
  },
}
