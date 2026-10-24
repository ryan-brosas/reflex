import QtQuick
import Quickshell
import Quickshell.Io

// reflexd's HTTP API, over XMLHttpRequest.
//
// The daemon binds 127.0.0.1 and wants a bearer token on every call. XHR keeps
// this to one engine object per request instead of a process: a panel that
// polls while it is open must not spawn a curl every two seconds.
//
// Every request carries a tag; the owner matches it in reply(tag, json) so a
// slow answer to an older question cannot overwrite a newer one.
Item {
  id: api
  visible: false

  property string baseUrl: "http://127.0.0.1:47823"
  property string token: ""
  property string tokenFile: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/reflex/token"
  property bool tokenLoaded: false
  property bool up: false
  property string lastError: ""
  property int inFlight: 0
  // Requests made before the token is read wait here, in order.
  property var waiting: []

  signal reply(string tag, var json)
  signal tokenFailed()

  readonly property bool ready: tokenLoaded && token !== ""

  function get(path, tag) { api.send("GET", path, "", tag) }
  function post(path, body, tag) { api.send("POST", path, body === undefined ? "{}" : body, tag) }

  function send(method, path, body, tag) {
    if (!api.ready) {
      var queued = api.waiting.slice()
      queued.push({ method: method, path: path, body: body, tag: tag })
      api.waiting = queued
      return
    }
    api.flush()
    var xhr = new XMLHttpRequest()
    xhr.open(method, api.baseUrl + path, true)
    xhr.setRequestHeader("authorization", "Bearer " + api.token)
    if (body !== "") xhr.setRequestHeader("content-type", "application/json")
    xhr.timeout = 8000
    api.inFlight += 1
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      api.inFlight = Math.max(0, api.inFlight - 1)
      var text = String(xhr.responseText === undefined ? "" : xhr.responseText)
      var json = null
      if (xhr.status === 200 && text !== "") {
        try { json = JSON.parse(text) } catch (e) { json = null }
      }
      api.up = xhr.status === 200
      api.lastError = xhr.status === 200 ? "" : ("http " + xhr.status + (text !== "" ? " " + text.substring(0, 120) : ""))
      api.reply(tag, json)
    }
    xhr.send(body === "" ? null : body)
  }

  // Anything queued before the token landed, in arrival order.
  function flush() {
    if (!api.ready || api.waiting.length === 0) return
    var queued = api.waiting
    api.waiting = []
    for (var i = 0; i < queued.length; i++) {
      var req = queued[i]
      api.send(req.method, req.path, req.body, req.tag)
    }
  }

  // The installer writes this file once (mode 0600) and never regenerates it
  // behind the user's back. One cat at load is cheaper than a watcher, and a
  // whole-buffer stdout collector reads the file in one piece: a partial read
  // here is a token that authenticates nothing.
  Process {
    id: tokenReader
    running: false
    command: ["cat", api.tokenFile]

    stdout: StdioCollector {
      id: tokenOut
      waitForEnd: true
      onStreamFinished: api.absorbToken(tokenOut.text)
    }

    onExited: function(code) {
      if (code !== 0) api.tokenFailed()
      else api.absorbToken(tokenOut.text)
    }
  }

  function absorbToken(raw) {
    var value = raw === undefined || raw === null ? "" : String(raw).trim()
    if (value === "") return
    if (api.tokenLoaded && value === api.token) return
    api.token = value
    api.tokenLoaded = true
    api.flush()
  }

  // A daemon restarted with a new token (or a first read that raced) needs a
  // re-read; the panel asks for one when a call comes back refused.
  function reauth() {
    api.tokenLoaded = false
    api.token = ""
    tokenReader.running = false
    tokenReader.running = true
  }

  Component.onCompleted: tokenReader.running = true
}
