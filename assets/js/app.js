// The web client's one script: it connects the page to its LiveView.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {},
})

liveSocket.connect()

// For debugging in the browser's console: liveSocket.enableDebug().
window.liveSocket = liveSocket
