// The hooks of the play page: the one script's three jobs. They hold no game
// logic: the server decides what a click means and whether it is allowed.
import {cellAtPixel, geometry, mirror, paint} from "./draw.js"

// Draws the scene the server puts on the canvas (`data-scene`), and says which
// cell a click fell on.
export const SceneCanvas = {
  mounted() {
    this.scene = null
    this.geo = null
    this.zoom = "near"
    this.onClick = (event) => {
      if (!this.geo) return
      const box = this.el.getBoundingClientRect()
      const cell = cellAtPixel(this.geo, event.clientX - box.left, event.clientY - box.top)
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
