// The web client's one script: it connects the page to its LiveView, and
// draws what the server sends (hooks.js, draw.js).
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {CommandLine, LogScroll, SceneCanvas, WorldCanvas} from "./hooks.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {CommandLine, LogScroll, SceneCanvas, WorldCanvas},
})

liveSocket.connect()

// For debugging in the browser's console: liveSocket.enableDebug().
window.liveSocket = liveSocket
