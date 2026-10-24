import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Reflex: every agent you run in herdr, and one ask bar that routes with Jev.
//
// Two modes in one surface:
//   list — who is working, who is blocked on a question (answer with 1, 2, 3),
//          what landed while you were away, what is still in the undo window
//   ask  — a few words find a session, a sentence becomes a request that
//          reflexd routes; Reflex decides where and when, your agent decides what
//
// All of it is a view over reflexd's HTTP API: routing, candidate ranking,
// question parsing and dispatch live in the Bend daemon (daemon/). This layer
// is a client, not a second implementation.
Item {
  id: root

  // Injected by the Omarchy shell when the plugin loads.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // Surface tokens: the popup palette, so a theme switch carries this with it.
  readonly property color background: Commons.Color.popups.background
  readonly property color foreground: Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
  readonly property string fontFamily: Style.font.family

  // State
  property bool opened: false
  property bool hidden: false
  property bool windowMaximized: false
  property string mode: "list"
  property string query: ""
  property string imePreedit: ""
  readonly property string sessionsHelper: (Quickshell.env("HOME") || "") + "/.local/lib/reflex/bin/reflex-sessions"
  property var replyCache: ({})
  property int replyRevision: 0
  property var attachments: []
  property bool pairOpen: false
  property bool doctorOpen: false
  property string doctorText: ""
  property string doctorError: ""
  property string pairUrl: ""
  property string pairImage: ""
  property string pairError: ""
  property bool pairPaired: false
  property bool pairExpired: false
  readonly property string pairFile: (Quickshell.env("HOME") || "") + "/.local/state/reflex/pair.txt"
  readonly property string pairQrFile: (Quickshell.env("HOME") || "") + "/.local/state/reflex/pair.png"
  property bool namingNew: false
  property string pendingRequest: ""
  property string pendingHarness: ""
  property bool sideForced: false
  property bool resumeOnly: false
  property bool terminalOpen: false
  property bool machinesOpen: false
  property bool setupOpen: false
  property bool settingsOpen: false
  property string settingsSection: "general"
  property string terminalPane: ""
  property string terminalTitle: ""
  property var pasts: []
  // The harness prefixes the Linux client understands. The daemon accepts the
  // same names in its harness field; the command tokens are handled in this
  // window because they are UI flows, not words to route.
  readonly property var harnesses: ["claude", "codex", "pi", "grok", "opencode", "amp", "gemini", "cursor", "droid", "copilot", "omp", "kimi"]
  property bool routing: false
  property string notice: ""
  property string noticeKind: "info"
  property int selectedIndex: 0
  property bool cursorActive: false
  property var state: ({})
  property var ranked: []
  property string rankedFor: ""
  property var rows: []
  property bool warnedOffline: false
  property string lastWhy: ""

  readonly property var agents: listOf(state.agents)
  readonly property var inbox: listOf(state.inbox)
  readonly property var pending: listOf(state.pending)
  readonly property var receipts: listOf(state.receipts)
  readonly property var questions: questionsOf(inbox)
  readonly property int workingCount: countStatus("working")
  readonly property bool online: api.up
  readonly property bool herdrOffline: state.herdr === false
  readonly property string startHerdrCommand: (Quickshell.env("HOME") || "") + "/.local/lib/reflex/bin/reflex-start-herdr"

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.pair === true) { root.startPair(); return }
    if (payload.doctor === true) { root.startDoctor(); return }
    if (payload.machines === true) { root.startMachines(); return }
    if (payload.setup === true) { root.startSetup(); return }
    if (payload.settings !== undefined) {
      root.startSettings(String(payload.settings === true ? "general" : payload.settings))
      return
    }
    var terminalWanted = String(payload.terminal === undefined ? "" : payload.terminal)
    if (terminalWanted !== "") { root.openTerminal(terminalWanted, String(payload.terminalTitle === undefined ? terminalWanted : payload.terminalTitle)); return }

    if (root.hidden) {
      // Restore a minimized window with its query and mode intact.
      root.hidden = false
      root.opened = true
      focusTimer.restart()
      Qt.callLater(function() { queryInput.forceActiveFocus() })
      root.refresh()
      return
    }
    var wasOpen = root.opened
    root.mode = payload.mode === "ask" ? "ask" : "list"
    root.query = String(payload.query === undefined ? "" : payload.query)
    root.attachments = []
    root.namingNew = false
    root.pendingRequest = ""
    root.pendingHarness = ""
    root.sideForced = false
    root.resumeOnly = false
    root.pasts = []
    root.notice = ""
    root.ranked = []
    root.rankedFor = ""
    root.routing = false
    root.selectedIndex = 0
    root.cursorActive = false
    if (!wasOpen) root.windowMaximized = false
    root.opened = true
    // Hyprland does not reliably focus a freshly mapped toplevel, and a repeat
    // summon must raise the window without remapping it (which would reset its
    // position). Wait for the map, then use Hyprland's own focus dispatcher —
    // the same path the herdr bar widget uses.
    focusTimer.restart()
    root.refresh()
    if (root.mode === "ask" && root.query !== "") searchTimer.restart()
    Qt.callLater(function() { queryInput.forceActiveFocus() })
  }

  function close() {
    root.hidden = false
    root.opened = false
    root.cursorActive = false
  }

  function startMachines() {
    root.hidden = false
    root.opened = false
    root.machinesOpen = true
  }

  function startSetup() {
    root.hidden = false
    root.opened = false
    root.setupOpen = true
  }

  function startSettings(section) {
    root.hidden = false
    root.opened = false
    root.settingsSection = String(section || "general")
    root.settingsOpen = true
  }

  function openTerminal(pane, title) {
    if (String(pane || "") === "") return
    root.hidden = false
    root.opened = false
    root.terminalPane = String(pane)
    root.terminalTitle = String(title || pane)
    // A closed toplevel can leave the flag true if the compositor closed it
    // instead of TerminalWindow.close(). Force a property transition so the
    // next summon creates a fresh terminal surface.
    if (root.terminalOpen) {
      root.terminalOpen = false
      Qt.callLater(function() { root.terminalOpen = true })
      return
    }
    root.terminalOpen = true
  }

  // Pairing owns a separate normal window: a QR card is a task you pick up a
  // phone for, not a row in the ask list. The helper writes the one-time code
  // and reflexd trades it once; the Windows/Mac QR never carries the token.
  function startPair() {
    root.hidden = false
    root.opened = false
    root.pairOpen = true
    root.pairUrl = ""
    root.pairImage = ""
    root.pairError = ""
    root.pairPaired = false
    root.pairExpired = false
    pairProcess.running = false
    pairProcess.running = true
    pairFocusTimer.restart()
    Qt.callLater(function() {
      if (typeof pairWindow.requestActivate === "function") pairWindow.requestActivate()
      pairFocus.forceActiveFocus()
    })
  }

  function pairReady(text) {
    var url = String(text || "").trim()
    if (url === "") { root.pairError = "Could not create a pairing code"; return }
    root.pairUrl = url
    pairQr.running = false
    pairQr.running = true
    pairFocusTimer.restart()
  }

  function pairQrReady(code) {
    if (Number(code) !== 0) { root.pairError = "qrencode is not installed"; return }
    root.pairImage = "file://" + root.pairQrFile + "?" + Date.now()
    if (typeof pairWindow.requestActivate === "function") pairWindow.requestActivate()
    pairFocus.forceActiveFocus()
    pairFocusTimer.restart()
  }

  function pairRemoteOff() {
    var home = Quickshell.env("HOME") || ""
    Quickshell.execDetached([home + "/.local/lib/reflex/bin/reflex-remote", "off"])
  }

  function closePair() {
    root.pairOpen = false
    pairProcess.running = false
    pairQr.running = false
    Quickshell.execDetached(["rm", "-f", root.pairFile])
    if (!root.pairPaired) root.pairRemoteOff()
  }

  function startDoctor() {
    root.hidden = false
    root.opened = false
    root.doctorOpen = true
    root.doctorText = "Checking…"
    root.doctorError = ""
    doctorProcess.running = false
    doctorProcess.running = true
    doctorFocusTimer.restart()
    Qt.callLater(function() {
      if (typeof doctorWindow.requestActivate === "function") doctorWindow.requestActivate()
      doctorFocus.forceActiveFocus()
    })
  }

  function doctorReady(text, code) {
    root.doctorText = String(text || "")
    if (Number(code) !== 0) root.doctorError = "Doctor found a failure; read the report."
    if (typeof doctorWindow.requestActivate === "function") doctorWindow.requestActivate()
    doctorFocus.forceActiveFocus()
    doctorFocusTimer.restart()
  }

  function closeDoctor() {
    root.doctorOpen = false
    doctorProcess.running = false
  }

  function dismiss() {
    root.hidden = false
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "reflex")
  }

  function toggle(payloadJson) {
    if (root.opened) root.dismiss()
    else root.open(payloadJson)
  }

  function setMode(next) {
    if (root.mode === next) return
    root.mode = next
    root.query = ""
    root.attachments = []
    root.namingNew = false
    root.pendingRequest = ""
    root.pendingHarness = ""
    root.sideForced = false
    root.resumeOnly = false
    root.ranked = []
    root.rankedFor = ""
    root.routing = false
    root.selectedIndex = 0
    root.cursorActive = false
    root.notice = ""
    root.rebuild()
  }

  function say(text, kind) {
    root.notice = String(text || "")
    root.noticeKind = kind || "info"
    noticeTimer.restart()
  }

  // ---------------------------------------------------------------- reading

  // One implementation, in Api.qml, because both this and the bar widget read
  // the same replies.
  function listOf(value) { return api.listOf(value) }

  function questionsOf(items) {
    var out = []
    var list = listOf(items)
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      if (!item) continue
      if (String(item.kind || "") !== "ask") continue
      if (listOf(item.options).length === 0) continue
      out.push(item)
    }
    return out
  }

  function countStatus(status) {
    var n = 0
    for (var i = 0; i < root.agents.length; i++)
      if (String(root.agents[i].status || "") === status) n += 1
    return n
  }

  function leaf(path) {
    var parts = String(path || "").split("/")
    for (var i = parts.length - 1; i >= 0; i--) if (parts[i] !== "") return parts[i]
    return "~"
  }

  function agentName(agent) {
    var name = String(agent.name || "")
    if (name === "") name = String(agent.kind || "agent")
    return name + " · " + leaf(agent.cwd)
  }

  function statusWord(status) {
    var s = String(status || "")
    if (s === "blocked") return "waits on you"
    if (s === "working") return "working"
    if (s === "done") return "done"
    if (s === "idle") return "idle"
    return s === "" ? "unknown" : s
  }

  function statusColor(status) {
    var s = String(status || "")
    if (s === "blocked") return root.urgent
    if (s === "working") return root.accent
    return root.dim
  }

  // A hard failure outranks a passing notice: "http 401" explains a panel that
  // looks empty, while "answered 1" does not.
  function listFooter() {
    if (api.lastError !== "") return api.lastError
    if (root.notice !== "") return root.notice
    return "1 2 3 answer · enter open · ⇧⏎ terminal · / ask"
  }

  function askFooter() {
    if (api.lastError !== "") return api.lastError
    if (root.notice !== "") return root.notice
    return "enter routes · tab sessions · esc close"
  }

  function weight(bp) {
    return Math.round((Number(bp) || 0) / 100) + "%"
  }

  // Agents read files by path, so a drop becomes a short "Files:" suffix on
  // the request. The routing words stay clean; only the dispatched text grows.
  function withFiles(text) {
    if (root.attachments.length === 0) return String(text || "")
    var suffix = "Files:\n" + root.attachments.join("\n")
    var body = String(text || "").trim()
    return body === "" ? suffix : body + "\n\n" + suffix
  }

  function fileName(path) {
    var s = String(path || "")
    var cut = s.lastIndexOf("/")
    return cut >= 0 ? s.substring(cut + 1) : s
  }

  function isImage(path) {
    return String(path || "").toLowerCase().match(/\.(png|jpe?g|webp|gif|bmp)$/) !== null
  }

  function fileUrl(path) {
    return "file://" + encodeURI(String(path || ""))
  }

  function addPaths(paths) {
    var next = root.attachments.slice()
    for (var i = 0; i < paths.length; i++) {
      var path = String(paths[i] || "").trim()
      if (path.indexOf("file://") === 0) path = decodeURIComponent(path.substring(7))
      if (path !== "" && next.indexOf(path) < 0) next.push(path)
    }
    if (next.length === root.attachments.length) return false
    root.attachments = next
    root.notice = ""
    root.rebuild()
    return true
  }

  function addDropped(drop) {
    root.addPaths(drop && drop.urls ? drop.urls : [])
  }

  function addPasted(text) {
    var paths = String(text || "").split("\n")
    if (!root.addPaths(paths))
      root.say("clipboard has no local file or image", "error")
    else
      root.say("attached from clipboard")
  }

  function removeAttachment(path) {
    var next = []
    for (var i = 0; i < root.attachments.length; i++)
      if (String(root.attachments[i]) !== String(path)) next.push(root.attachments[i])
    root.attachments = next
    root.rebuild()
  }

  function pasteAttachment() {
    if (pasteProcess.running) return
    root.say("reading clipboard…", "ask")
    pasteProcess.running = true
  }

  // "/pi fix the bug" is the request "fix the bug" with harness pi. The Mac
  // app parses its slash tokens client-side; these are the same client-side
  // flows: @machine, /harness, /new, /folder, /resume and /btw. The daemon
  // still owns ranking, questions and dispatch.
  function parseQuery(raw) {
    var text = String(raw || "").trim()
    var machine = ""
    if (text.charAt(0) === "@") {
      var afterAt = text.substring(1)
      var atCut = afterAt.indexOf(" ")
      machine = (atCut < 0 ? afterAt : afterAt.substring(0, atCut)).toLowerCase()
      text = atCut < 0 ? "" : afterAt.substring(atCut + 1).trim()
    }
    if (text.charAt(0) === "/") {
      var rest = text.substring(1)
      var cut = rest.indexOf(" ")
      var token = (cut < 0 ? rest : rest.substring(0, cut)).toLowerCase()
      var body = cut < 0 ? "" : rest.substring(cut + 1).trim()
      if (root.harnesses.indexOf(token) >= 0)
        return { harness: token, text: body, command: "", machine: machine }
      if (token === "new" || token === "folder" || token === "resume" || token === "btw" || token === "paste" || token === "attach" || token === "pair" || token === "doctor" || token === "machines" || token === "setup" || token === "settings")
        return { harness: "", text: body, command: token, machine: machine }
    }
    return { harness: "", text: text, command: "", machine: machine }
  }

  // New folders live under ~/Projects on this machine; reflexd's spawn makes
  // the directory (mkdir_here in daemon/main.bend), so the UI does not need
  // shell access for it. Names are slashes/dots safe before they become a path.
  function newParent() {
    return (Quickshell.env("HOME") || "") + "/Projects"
  }

  function startNew(text, harness) {
    root.pendingRequest = String(text || "")
    root.pendingHarness = String(harness || "")
    root.namingNew = true
    root.query = ""
    root.ranked = []
    root.rankedFor = ""
    root.notice = "Name the new folder"
    root.noticeKind = "ask"
    root.rebuild()
  }

  function createNew() {
    var raw = root.query.trim()
    if (raw === "") { root.say("type a folder name", "ask"); return }
    var name = raw.split("/").join("-").split("..").join("-")
    name = name.replace(/[^A-Za-z0-9._ -]/g, "-").trim().split(" ").join("-")
    if (name === "" || name === "." || name === "..") name = "new-project"
    var path = root.newParent() + "/" + name
    var body = { cwd: path, text: root.withFiles(root.pendingRequest) }
    if (root.pendingHarness !== "") body.kind = root.pendingHarness
    api.post("/api/spawn", JSON.stringify(body), "run")
    root.say("new folder · " + name)
    root.namingNew = false
    root.pendingRequest = ""
    root.pendingHarness = ""
    root.query = ""
    root.attachments = []
    root.rebuild()
  }

  function chooseFolder(text, harness) {
    root.pendingRequest = String(text || "")
    root.pendingHarness = String(harness || "")
    root.say("choose a folder…", "ask")
    folderDialog.open()
  }

  function folderChosen(path) {
    var cwd = String(path || "").trim()
    if (cwd.indexOf("file://") === 0) cwd = decodeURIComponent(cwd.substring(7))
    if (cwd === "") {
      root.say("folder picker cancelled", "error")
      focusTimer.restart()
      Qt.callLater(function() { queryInput.forceActiveFocus() })
      return
    }
    var body = { cwd: cwd, text: root.withFiles(root.pendingRequest) }
    if (root.pendingHarness !== "") body.kind = root.pendingHarness
    api.post("/api/spawn", JSON.stringify(body), "run")
    root.say("started in " + cwd.split("/").pop())
    root.pendingRequest = ""
    root.pendingHarness = ""
    root.query = ""
    root.attachments = []
    root.rebuild()
    focusTimer.restart()
    Qt.callLater(function() { queryInput.forceActiveFocus() })
  }

  function initials(kind) {
    var k = String(kind || "")
    if (k === "") return "·"
    return k.substring(0, 2)
  }

  // -------------------------------------------------------------------- rows

  function rebuild() {
    var out = []

    if (root.mode === "ask") {
      if (root.namingNew) {
        out.push({ kind: "hint", label: "Name the new folder" })
        if (root.pendingRequest !== "") out.push({ kind: "hint", label: "for: " + root.pendingRequest })
        out.push({ kind: "hint", label: "enter creates it under ~/Projects · esc cancels" })
        root.rows = out
        root.clampSelection()
        return
      }

      if (root.resumeOnly) {
        var rq = String(root.parseQuery(root.query).text || "").toLowerCase()
        for (var p = 0; p < root.pasts.length && out.length < 12; p++) {
          var past = root.pasts[p]
          var hay = [String(past.title || ""), String(past.last || ""), String(past.cwd || ""), String(past.agent || "")].join(" ").toLowerCase()
          if (rq !== "" && hay.indexOf(rq) < 0) continue
          var pastState = String(past.state || "")
          var mode = pastState === "running" ? "attach" : (pastState === "elsewhere" ? "fork" : "resume")
          var action = { type: "resume", cwd: past.cwd, kind: past.agent, session: past.id, mode: mode, text: "" }
          out.push({
            kind: "past",
            past: { label: String(past.title || "earlier session"), action: action },
            label: String(past.title || "earlier session"),
            detail: String(past.agent || "") + " · " + String(past.cwd || "").split("/").pop() + " · " + String(past.ageHours || 0) + "h"
          })
        }
        if (out.length === 0) out.push({ kind: "hint", label: root.pasts.length === 0 ? "Loading earlier sessions…" : "No earlier session matches." })
        root.rows = out
        root.clampSelection()
        return
      }

      for (var i = 0; i < root.ranked.length; i++) {
        var r = root.ranked[i]
        var actionType = r.action && r.action.type ? String(r.action.type) : ""
        if (root.sideForced && actionType !== "prompt") continue
        out.push({
          kind: "ranked",
          ranked: r,
          label: String(r.label || ""),
          detail: weight(r.bp),
          best: i === 0
        })
      }
      if (out.length === 0) {
        var parsed = root.parseQuery(root.query)
        var text = parsed.text
        if (text === "") {
          if (root.sideForced) {
            out.push({ kind: "hint", label: "Type the side question; only live sessions can take /btw." })
          } else if (parsed.harness !== "") {
            out.push({ kind: "hint", label: "Type the request for " + parsed.harness + "." })
          } else {
            out.push({ kind: "hint", label: "A few words find a session. A sentence goes to one." })
            var commands = [
              { token: "/claude", name: "Claude" },
              { token: "/pi", name: "pi" },
              { token: "/codex", name: "Codex" },
              { token: "/folder", name: "any folder" },
              { token: "/new", name: "new folder" },
              { token: "/resume", name: "earlier session" },
              { token: "/btw", name: "side question" },
              { token: "/paste", name: "file from clipboard" },
              { token: "/pair", name: "phone QR" },
              { token: "/doctor", name: "readiness checks" },
              { token: "/machines", name: "SSH machines" },
              { token: "/setup", name: "guided setup" },
              { token: "/settings", name: "settings" }
            ]
            for (var c = 0; c < commands.length; c++)
              out.push({ kind: "command", command: commands[c].token, label: commands[c].token, detail: commands[c].name })
            out.push({ kind: "hint", label: root.agents.length + " live sessions · " + root.questions.length + " waiting on you" })
          }
        } else {
          out.push({ kind: "hint", label: root.rankedFor === text ? "Nothing matches." : "Searching…" })
        }
      }
      for (var a = 0; a < root.attachments.length; a++) {
        var path = String(root.attachments[a])
        out.push({ kind: "attachment", attachment: path, label: root.fileName(path), detail: path })
      }
      root.rows = out
      root.clampSelection()
      return
    }

    if (root.herdrOffline) {
      out.push({ kind: "offline", label: "herdr isn't running", detail: "enter starts it · sessions return when it does" })
      root.rows = out
      root.selectedIndex = 0
      root.cursorActive = true
      return
    }

    for (var q = 0; q < root.questions.length; q++) {
      var item = root.questions[q]
      out.push({ kind: "question", item: item, label: String(item.title || "a question"), detail: String(item.body || "") })
      var options = listOf(item.options)
      for (var o = 0; o < options.length; o++) {
        var opt = options[o]
        out.push({
          kind: "option",
          item: item,
          key: String(opt.key || ""),
          label: String(opt.label || ""),
          detail: q === 0 ? "press " + String(opt.key || "") : ""
        })
      }
    }

    for (var p = 0; p < root.pending.length; p++) {
      var d = root.pending[p]
      out.push({
        kind: "pending",
        dispatch: d,
        label: String(d.label || "dispatch"),
        detail: "in " + Math.max(0, Math.round((Number(d.left) || 0) / 1000)) + "s · enter cancels"
      })
    }

    var ordered = orderAgents(root.agents)
    for (var a = 0; a < ordered.length; a++) {
      var agent = ordered[a]
      out.push({
        kind: "agent",
        agent: agent,
        label: agentName(agent),
        detail: statusWord(agent.status) + (String(agent.title || "") !== "" ? " · " + String(agent.title) : ""),
        state: String(agent.status || "")
      })
    }

    for (var u = 0; u < root.inbox.length; u++) {
      var update = root.inbox[u]
      if (String(update.kind || "") === "ask") continue
      out.push({ kind: "update", item: update, label: String(update.title || "update"), detail: root.replyFor(update) })
    }

    for (var t = 0; t < root.receipts.length && t < 4; t++) {
      var receipt = root.receipts[t]
      out.push({
        kind: "receipt",
        label: String(receipt.label || ""),
        detail: receipt.ok === true ? String(receipt.detail || "done") : String(receipt.detail || "failed"),
        state: receipt.ok === true ? "working" : "blocked"
      })
    }

    if (out.length === 0) {
      out.push({
        kind: "hint",
        label: root.online
          ? "No agents in herdr yet. Start one, then ask."
          : "reflexd is not answering. systemctl --user status reflexd"
      })
    }

    root.rows = out
    root.clampSelection()
  }

  // Blocked first, then working, then the rest; newest change on top.
  function agentFor(pane) {
    var wanted = String(pane || "")
    if (wanted === "") return null
    for (var i = 0; i < root.agents.length; i++)
      if (String(root.agents[i].pane || "") === wanted) return root.agents[i]
    return null
  }

  function replyFor(item) {
    if (!item) return ""
    var id = Number(item.id) || 0
    if (root.replyCache[id] !== undefined && String(root.replyCache[id] || "") !== "")
      return String(root.replyCache[id])
    return String(item.body || "")
  }

  function ensureReplyFor(item) {
    if (!item || String(item.kind || "") !== "ready") return
    var agent = root.agentFor(item.pane)
    if (!agent) return
    var kind = String(agent.kind || "")
    var session = String(agent.session || "")
    if ((kind !== "claude" && kind !== "pi") || session === "") return
    var id = Number(item.id) || 0
    if (id <= 0 || replyProcess.running) return
    if (root.replyCache[id] !== undefined && String(root.replyCache[id] || "") !== "") return
    replyProcess.itemId = id
    replyProcess.command = [root.sessionsHelper, "reply", kind, session]
    replyProcess.running = true
  }

  function refreshReplies() {
    if (!root.opened || replyProcess.running) return
    for (var i = 0; i < root.inbox.length; i++) {
      root.ensureReplyFor(root.inbox[i])
      if (replyProcess.running) return
    }
  }

  function orderAgents(list) {
    var rank = { blocked: 0, working: 1, done: 2, idle: 3, unknown: 4 }
    var copy = listOf(list).slice()
    copy.sort(function(x, y) {
      var rx = rank[String(x.status || "unknown")]
      var ry = rank[String(y.status || "unknown")]
      if (rx === undefined) rx = 4
      if (ry === undefined) ry = 4
      if (rx !== ry) return rx - ry
      return (Number(y.seq) || 0) - (Number(x.seq) || 0)
    })
    return copy
  }

  function clampSelection() {
    if (root.rows.length === 0) {
      root.selectedIndex = 0
      root.cursorActive = false
      return
    }
    if (root.selectedIndex >= root.rows.length) root.selectedIndex = root.rows.length - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  function select(delta) {
    if (root.rows.length === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? root.rows.length - 1 : 0
    } else {
      root.selectedIndex = (root.selectedIndex + delta + root.rows.length) % root.rows.length
    }
    list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function activate() {
    if (!root.cursorActive) {
      if (root.mode === "ask") root.route()
      return
    }
    var row = root.rows[root.selectedIndex]
    if (!row) return

    if (row.kind === "offline") {
      root.startHerdr()
    } else if (row.kind === "command") {
      root.editQuery(String(row.command || "") + " ")
    } else if (row.kind === "attachment") {
      root.removeAttachment(String(row.attachment || ""))
    } else if (row.kind === "past") {
      root.run(row.past.action, String(row.past.label || ""))
    } else if (row.kind === "option") {
      root.answer(row.item, row.key)
    } else if (row.kind === "question") {
      var options = listOf(row.item.options)
      if (options.length > 0) root.answer(row.item, String(options[0].key || "1"))
    } else if (row.kind === "agent") {
      api.post("/api/focus", JSON.stringify({ pane: String(row.agent.pane || "") }), "focus")
      root.dismiss()
    } else if (row.kind === "pending") {
      api.post("/api/cancel", JSON.stringify({ id: Number(row.dispatch.id) || 0 }), "cancel")
      root.say("cancelled " + String(row.dispatch.label || ""))
    } else if (row.kind === "ranked") {
      root.run(row.ranked.action, row.label)
    } else if (row.kind === "update") {
      api.post("/api/dismiss", JSON.stringify({ item: Number(row.item.id) || 0 }), "dismiss")
      root.say("cleared")
    } else if (root.mode === "ask") {
      root.route()
    }
  }

  // herdr is a separately owned server. Reflex shows its state and starts it
  // the native way (a terminal running herdr); it does not supervise it.
  function startHerdr() {
    Quickshell.execDetached([root.startHerdrCommand])
    root.dismiss()
  }

  // The titlebar controls and the shell's call() IPC share these; a window
  // control is not routing logic, it is the app frame. Wayland xdg-toplevel has
  // no minimize request, so minimize unmaps the window and keeps the plugin
  // (query, mode, maximized state) alive for the next summon. Maximize uses
  // Hyprland's own fullscreen/maximize path; Quickshell's property is a no-op
  // on this compositor.
  function minimizeWindow() { root.hidden = true }
  function toggleMaximize() {
    root.windowMaximized = !root.windowMaximized
    Quickshell.execDetached(["hyprctl", "eval", root.windowMaximized
      ? "hl.dispatch(hl.dsp.window.fullscreen(1))"
      : "hl.dispatch(hl.dsp.window.fullscreen(0))"])
  }

  // Shift+Enter on a session opens the embedded terminal on that pane. Herdr
  // still owns the PTY and the native terminal remains one click away; this is
  // only the view over herdr's own terminal stream.
  function attachSelected() {
    var row = root.rows[root.selectedIndex]
    if (!row || row.kind !== "agent") return false
    root.openTerminal(String(row.agent.pane || ""), String(row.agent.title || row.agent.name || ""))
    return true
  }

  // ---------------------------------------------------------------- actions

  function answer(item, key) {
    if (!item) return
    api.post("/api/answer", JSON.stringify({ item: Number(item.id) || 0, key: String(key || "") }), "answer")
    root.say("answered " + String(key || ""))
  }

  // One place every routing action becomes an API call, so a new action kind in
  // daemon/Model.bend is one line here instead of a code path per view. The
  // window stays open so the receipt is readable; esc or the close button ends it.
  function run(action, label) {
    if (!action || !action.type) return
    var type = String(action.type)
    var text = root.withFiles(action.text)
    if (root.sideForced) {
      if (type !== "prompt") {
        root.say("choose a live session for /btw", "error")
        return
      }
      api.post("/api/side", JSON.stringify({ pane: action.pane, text: text }), "run")
      root.attachments = []
      root.sideForced = false
      root.say("btw → " + String(label || "live session"))
      return
    }
    if (type === "prompt") {
      api.post("/api/send", JSON.stringify({ pane: action.pane, text: text, label: label || "" }), "run")
    } else if (type === "spawn") {
      api.post("/api/spawn", JSON.stringify({ cwd: action.cwd, kind: action.kind, text: text }), "run")
    } else if (type === "resume") {
      api.post("/api/resume", JSON.stringify({ cwd: action.cwd, kind: action.kind, session: action.session, mode: action.mode, text: text }), "run")
    } else if (type === "press") {
      api.post("/api/keys", JSON.stringify({ pane: action.pane, key: action.key }), "run")
    } else if (type === "btw" || type === "fork") {
      api.post("/api/side", JSON.stringify({ pane: action.pane, text: text }), "run")
    } else {
      root.say("action this layer does not know: " + type, "error")
      return
    }
    root.attachments = []
    root.say("→ " + String(label || type))
  }

  // Send the typed request. /api/route is a write unless dry is set: the
  // daemon enqueues a dispatch and also returns the decision. Ask for the
  // decision only, then call exactly one write endpoint in run(). Without
  // dry the daemon dispatches and this window dispatches again.
  function route() {
    if (root.namingNew) { root.createNew(); return }
    var parsed = root.parseQuery(root.query)
    root.sideForced = parsed.command === "btw"
    root.resumeOnly = parsed.command === "resume"
    if (parsed.command === "folder") { root.chooseFolder(parsed.text, parsed.harness); return }
    if (parsed.command === "new") { root.startNew(parsed.text, parsed.harness); return }
    if (parsed.command === "pair") { root.startPair(); return }
    if (parsed.command === "doctor") { root.startDoctor(); return }
    if (parsed.command === "machines") { root.startMachines(); return }
    if (parsed.command === "setup") { root.startSetup(); return }
    if (parsed.command === "settings") { root.startSettings(); return }
    if (parsed.command === "paste") { root.pasteAttachment(); return }
    if (parsed.command === "attach") {
      var attachPath = String(parsed.text || "").trim()
      if (attachPath === "") root.say("type a path after /attach", "ask")
      else if (!root.addPaths([attachPath])) root.say("already attached", "ask")
      else root.say("attached " + root.fileName(attachPath))
      return
    }
    if (parsed.command === "resume") {
      var row = root.rows[root.selectedIndex]
      if (root.cursorActive && row && row.kind === "past") { root.run(row.past.action, row.past.label); return }
      if (root.pasts.length === 0) { api.get("/api/sessions", "pasts"); return }
      root.say("choose an earlier session", "ask")
      return
    }
    var text = parsed.text
    if (text === "") {
      var what = parsed.harness !== "" ? " for " + parsed.harness : (parsed.command === "btw" ? " for /btw" : "")
      root.say("type a request" + what, "ask")
      return
    }
    if (root.routing) return
    root.routing = true
    var body = { text: text, dry: true }
    if (parsed.harness !== "") body.harness = parsed.harness
    if (parsed.machine !== "") body.machine = parsed.machine
    api.post("/api/route", JSON.stringify(body), "route")
  }

  function routeReply(json) {
    root.routing = false
    if (!json || json.ok !== true || !json.route) {
      root.say(json && json.error ? String(json.error) : "reflexd did not route that", "error")
      return
    }
    // A route reply carrying a dispatch means the daemon already wrote the
    // action. Never run it a second time.
    if (json.dispatch) {
      root.say("reflexd already dispatched that; not sending twice", "error")
      return
    }
    var decision = json.route
    var kind = String(decision.decision || "")
    if (kind === "go") {
      root.run(decision.action, String(decision.label || ""))
      return
    }
    if (kind === "choose") {
      var opts = listOf(decision.options)
      var out = []
      for (var i = 0; i < opts.length; i++) {
        if (root.sideForced && String(opts[i].action && opts[i].action.type || "") !== "prompt") continue
        out.push({
          kind: "ranked",
          ranked: { label: String(opts[i].label || ""), action: opts[i].action, key: String(opts[i].key || "") },
          label: String(opts[i].label || ""),
          detail: String(opts[i].key || ""),
          best: i === 0
        })
      }
      root.rows = out
      root.selectedIndex = 0
      root.cursorActive = out.length > 0
      root.say(String(decision.title || "where should this go?"), "ask")
      return
    }
    root.say(String(decision.error || "nothing to route to"), "error")
  }

  // --------------------------------------------------------------- requests

  function refresh() {
    if (!root.opened) return
    api.get("/api/state", "state")
  }

  function searchCandidates() {
    var parsed = root.parseQuery(root.query)
    root.sideForced = parsed.command === "btw"
    root.resumeOnly = parsed.command === "resume"
    if (root.namingNew) { root.rebuild(); return }
    if (root.resumeOnly) {
      if (root.pasts.length === 0) api.get("/api/sessions", "pasts")
      else root.rebuild()
      return
    }
    var text = parsed.text
    if (text === "") {
      root.ranked = []
      root.rankedFor = ""
      root.rebuild()
      return
    }
    var body = { text: text }
    if (parsed.harness !== "") body.harness = parsed.harness
    if (parsed.machine !== "") body.machine = parsed.machine
    api.post("/api/candidates", JSON.stringify(body), "candidates")
  }

  function onReply(tag, json) {
    if (tag === "state") {
      // /api/state is the snapshot itself, not an {ok:…} envelope: the shape
      // that tells them apart is "now"/"agents", while every other endpoint
      // answers inside {ok:…}.
      if (json && (json.agents !== undefined || json.now !== undefined)) {
        root.state = json
        root.warnedOffline = false
        root.rebuild()
        return
      }
      // A 401 is the one failure that looks like an empty state: the daemon
      // answered, so nothing is "offline", but every read came back refused.
      var why = json && json.error ? String(json.error) : "reflexd did not answer with state"
      // A refused token is recoverable: re-read it and let the next poll through.
      if (why === "bad token") api.reauth()
      if (!root.warnedOffline || why !== root.lastWhy) {
        root.warnedOffline = true
        root.lastWhy = why
        root.say(why + " · systemctl --user status reflexd", "error")
      }
      root.state = ({})
      root.rebuild()
      return
    }
    if (tag === "pasts") {
      if (!json || json.ok !== true) {
        root.say(json && json.error ? String(json.error) : "could not read earlier sessions", "error")
        return
      }
      if (root.mode !== "ask") return
      root.pasts = listOf(json.sessions)
      root.resumeOnly = true
      root.rebuild()
      return
    }
    if (tag === "candidates") {
      if (!json || json.ok !== true) {
        root.say(json && json.error ? String(json.error) : "search failed", "error")
        return
      }
      if (root.mode !== "ask") return
      root.ranked = listOf(json.ranked)
      root.rankedFor = root.parseQuery(root.query).text
      root.cursorActive = false
      root.selectedIndex = 0
      root.rebuild()
      return
    }
    if (tag === "route") {
      root.routeReply(json)
      return
    }
    if (tag === "run") {
      if (json && json.ok === true) root.say("sent · " + String(json.label || ""))
      else root.say(json && json.error ? String(json.error) : "reflexd did not take that", "error")
      root.refresh()
      return
    }
    if (tag === "focus" || tag === "answer" || tag === "dismiss" || tag === "cancel") {
      root.refresh()
    }
  }

  // ------------------------------------------------------------------ input

  function editQuery(text) {
    root.query = text
    root.cursorActive = false
    root.selectedIndex = 0
    searchTimer.restart()
    root.rebuild()
  }

  function answerWaiting(key) {
    var first = root.questions.length > 0 ? root.questions[0] : null
    if (!first) return false
    var options = listOf(first.options)
    for (var i = 0; i < options.length; i++) {
      if (String(options[i].key || "") === String(key)) {
        root.answer(first, key)
        return true
      }
    }
    return false
  }

  function onKey(event) {
    var code = event.key

    if (code === Qt.Key_Escape) {
      if (root.mode === "ask" && root.namingNew) {
        root.namingNew = false
        root.query = root.pendingRequest
        root.pendingRequest = ""
        root.pendingHarness = ""
        root.notice = ""
        searchTimer.restart()
        root.rebuild()
      } else if (root.mode === "ask" && root.query !== "") root.editQuery("")
      else if (root.mode === "ask" && root.attachments.length > 0) { root.attachments = []; root.rebuild() }
      else root.dismiss()
      event.accepted = true
      return
    }
    if (code === Qt.Key_V && (event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier)) {
      root.pasteAttachment()
      event.accepted = true
      return
    }

    if (code === Qt.Key_Tab || code === Qt.Key_Backtab) {
      root.setMode(root.mode === "ask" ? "list" : "ask")
      event.accepted = true
      return
    }
    if (code === Qt.Key_Down) { root.select(1); event.accepted = true; return }
    if (code === Qt.Key_Up) { root.select(-1); event.accepted = true; return }
    if (code === Qt.Key_PageDown) { root.select(6); event.accepted = true; return }
    if (code === Qt.Key_PageUp) { root.select(-6); event.accepted = true; return }
    if (code === Qt.Key_Return || code === Qt.Key_Enter) {
      if ((event.modifiers & Qt.ShiftModifier) !== 0 && root.attachSelected()) { event.accepted = true; return }
      root.activate(); event.accepted = true; return
    }
    if (code === Qt.Key_Backspace) {
      if (root.mode === "ask" && root.query !== "") {
        var chars = root.query.split("")
        chars.pop()
        root.editQuery(chars.join(""))
      }
      event.accepted = true
      return
    }

    var text = String(event.text || "")
    if (text === "") return
    var ch = text.charCodeAt(0)
    if (ch < 32) { event.accepted = true; return }

    // 1, 2, 3 answer the question waiting on you: the same reflex as the
    // macOS rail. In the ask bar digits are only ever text.
    if (text.length === 1 && root.mode === "list" && ch >= 49 && ch <= 57) {
      if (root.answerWaiting(text)) { event.accepted = true; return }
    }
    if (text.length === 1 && root.mode === "list" && text === "/") {
      root.setMode("ask")
      event.accepted = true
      return
    }
    // Printable text belongs to queryInput, which also receives IME commits
    // and preedit. Swallowing it here would bypass fcitx entirely.
    if (!(event.modifiers & (Qt.ControlModifier | Qt.AltModifier))) return
    event.accepted = true
  }

  // ------------------------------------------------------------------ timers

  Timer {
    id: stateTimer
    interval: 2000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: replyTimer
    interval: 1500
    repeat: true
    running: root.opened && root.inbox.length > 0
    onTriggered: root.refreshReplies()
  }

  Timer {
    id: searchTimer
    interval: 260
    running: false
    repeat: false
    onTriggered: root.searchCandidates()
  }

  Timer {
    id: focusTimer
    interval: 180
    repeat: false
    onTriggered: Quickshell.execDetached(["hyprctl", "eval", "hl.dispatch(hl.dsp.focus({ window = \"title:^Reflex$\" }))"])
  }

  Timer {
    id: noticeTimer
    interval: 4000
    running: false
    repeat: false
    onTriggered: root.notice = ""
  }

  // /folder uses Qt's native folder dialog (the desktop portal on Wayland)
  // rather than an external zenity process. The dialog owns Escape and Cancel;
  // the ask window stays behind it and takes focus back when it closes.
  FolderDialog {
    id: folderDialog
    title: "Reflex: choose a folder"
    modality: Qt.ApplicationModal
    onAccepted: root.folderChosen(String(folderDialog.selectedFolder))
    onRejected: root.folderChosen("")
  }

  // Ctrl+Shift+V and /paste read a copied local file or image. The script owns
  // the Wayland clipboard details; the QML stays a path list.
  Process {
    id: replyProcess
    property int itemId: 0
    running: false
    command: []
    stdout: StdioCollector { id: replyOut; waitForEnd: true }
    stderr: StdioCollector { id: replyErr; waitForEnd: true }
    onExited: function(code, status) {
      var id = replyProcess.itemId
      if (id > 0) {
        try {
          var parsed = JSON.parse(String(replyOut.text || "{}"))
          var text = parsed && parsed.ok === true ? String(parsed.reply || "") : ""
          if (text !== "") root.replyCache[id] = text
        } catch (e) {}
        root.replyRevision += 1
        root.rebuild()
      }
      replyProcess.itemId = 0
    }
  }

  Process {
    id: pasteProcess
    running: false
    command: [(Quickshell.env("HOME") || "") + "/.local/lib/reflex/bin/reflex-attach-paste"]
    stdout: StdioCollector {
      id: pasteOut
      waitForEnd: true
    }
    onExited: root.addPasted(pasteOut.text)
  }

  Process {
    id: pairProcess
    running: false
    command: [(Quickshell.env("HOME") || "") + "/.local/lib/reflex/bin/reflex-pair"]
    stdout: StdioCollector {
      id: pairOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: pairErr
      waitForEnd: true
    }
    onExited: function(code, status) {
      if (Number(code) !== 0) root.pairError = String(pairErr.text || "").trim() || "Pair helper failed"
      else root.pairReady(pairOut.text)
    }
  }

  Process {
    id: pairQr
    running: false
    command: ["/usr/bin/qrencode", "-o", root.pairQrFile, "-s", "6", "-m", "2", root.pairUrl]
    onExited: function(code, status) { root.pairQrReady(code) }
  }

  FileView {
    id: pairWatch
    path: root.pairFile
    watchChanges: true
    preload: true
    onTextChanged: {
      if (root.pairOpen && root.pairUrl !== "" && !root.pairExpired && text().trim() === "")
        root.pairPaired = true
    }
  }

  Timer {
    id: pairFocusTimer
    interval: 120
    repeat: false
    onTriggered: {
      if (typeof pairWindow.requestActivate === "function") pairWindow.requestActivate()
      pairFocus.forceActiveFocus()
    }
  }

  Timer {
    id: pairExpiry
    interval: 600000
    repeat: false
    running: root.pairOpen && root.pairUrl !== ""
    onTriggered: {
      root.pairExpired = true
      root.pairPaired = false
      root.pairUrl = ""
      root.pairImage = ""
      root.pairRemoteOff()
    }
  }

  Process {
    id: doctorProcess
    running: false
    command: [(Quickshell.env("HOME") || "") + "/.local/lib/reflex/bin/reflex-doctor"]
    stdout: StdioCollector {
      id: doctorOut
      waitForEnd: true
    }
    onExited: function(code, status) { root.doctorReady(doctorOut.text, code) }
  }

  Timer {
    id: doctorFocusTimer
    interval: 120
    repeat: false
    onTriggered: {
      if (typeof doctorWindow.requestActivate === "function") doctorWindow.requestActivate()
      doctorFocus.forceActiveFocus()
    }
  }

  Api {
    id: api
    onReply: function(tag, json) { root.onReply(tag, json) }
    onTokenFailed: root.say("no API token. Run linux/install-omarchy.sh.", "error")
  }

  // -------------------------------------------------------------------- view

  // A normal toplevel, not a layer surface: Hyprland tiles it like every other
  // app. It is intentionally not floated; if you toggle floating with your
  // compositor bind, the header is its drag handle and the corner its resize grip.
  FloatingWindow {
    id: panel
    title: "Reflex"
    visible: root.opened && !root.hidden
    color: "transparent"
    implicitWidth: 760
    implicitHeight: 540
    minimumSize: Qt.size(560, 360)
    onVisibleChanged: {
      if (!visible && root.opened && !root.hidden) root.opened = false
    }

    BorderSurface {
      id: card
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent }

      DropArea {
        anchors.fill: parent
        onDropped: function(drop) { root.addDropped(drop) }
      }

      FocusScope {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        TextInput {
          id: queryInput
          width: 1
          height: 1
          opacity: 0.01
          color: "transparent"
          selectionColor: "transparent"
          selectedTextColor: "transparent"
          cursorVisible: false
          activeFocusOnPress: false
          inputMethodHints: Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.onKey(event) }
          onTextEdited: {
            var text = queryInput.text
            if (text !== "") {
              if (root.mode !== "ask") root.setMode("ask")
              root.editQuery(root.query + text)
              queryInput.clear()
            }
          }
          onPreeditTextChanged: root.imePreedit = queryInput.preeditText
        }

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.space(10)

          // header: mode, counts, keys; the empty header is the drag handle
          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.font.caption + Style.space(8)

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton
              cursorShape: Qt.SizeAllCursor
              onPressed: panel.startSystemMove()
            }

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: "REFLEX"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.2
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                width: Style.space(1)
                height: Style.font.caption
                color: root.dim
                opacity: 0.4
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: {
                  if (root.questions.length > 0) return root.questions.length + " waiting on you"
                  if (root.workingCount > 0) return root.workingCount + " working · " + root.agents.length + " sessions"
                  if (root.agents.length > 0) return root.agents.length + " sessions"
                  return root.online ? "no sessions" : "reflexd down"
                }
                color: root.questions.length > 0 ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)

              Text {
                text: root.mode === "ask" ? "tab · sessions" : "tab · ask"
                color: root.dim
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: "esc"
                color: root.dim
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: "−"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.minimizeWindow()
                }
              }

              Text {
                text: root.windowMaximized ? "❐" : "□"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleMaximize()
                }
              }

              Text {
                text: "✕"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter

                MouseArea {
                  anchors.fill: parent
                  anchors.margins: -Style.space(6)
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.dismiss()
                }
              }
            }
          }

          // the ask line
          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(34)
            visible: root.mode === "ask"

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: "transparent"
              border.width: 1
              border.color: Commons.Color.popups.border
            }

            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              text: root.query === "" && root.imePreedit === "" ? "Where should this go?" : root.query + root.imePreedit
              color: root.query === "" && root.imePreedit === "" ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }
          }

          // rows
          ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: Style.space(2)
            clip: true
            model: root.rows
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(1)

            delegate: Item {
              id: rowItem
              required property var modelData
              required property int index

              readonly property bool selected: root.cursorActive && root.selectedIndex === index
              readonly property color rowState: modelData.kind === "ranked"
                ? (modelData.best === true ? root.accent : root.dim)
                : (modelData.kind === "attachment" ? root.accent : root.statusColor(modelData.state))

              width: ListView.view ? ListView.view.width : 0
              height: Math.max(Style.space(28), rowText.implicitHeight + Style.spacing.controlPaddingY)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: Style.selectedFillFor(root.foreground, rowItem.rowState)
                opacity: rowItem.selected ? 0.9 : 0
              }

              Rectangle {
                width: Style.space(2)
                height: parent.height - Style.space(8)
                anchors.left: parent.left
                anchors.leftMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                radius: 1
                color: rowItem.rowState
                opacity: modelData.kind === "hint" ? 0 : (rowItem.selected ? 1 : 0.55)
              }

              Rectangle {
                id: thumbBox
                visible: rowItem.modelData.kind === "attachment"
                width: visible ? Style.space(24) : 0
                height: width
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                radius: 4
                color: Style.selectedFillFor(root.foreground, root.accent)
                clip: true

                Image {
                  anchors.fill: parent
                  visible: root.isImage(String(rowItem.modelData.attachment || ""))
                  source: visible ? root.fileUrl(String(rowItem.modelData.attachment || "")) : ""
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: false
                }

                Text {
                  anchors.centerIn: parent
                  visible: !root.isImage(String(rowItem.modelData.attachment || ""))
                  text: "▣"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Column {
                id: rowText
                anchors.left: thumbBox.visible ? thumbBox.right : parent.left
                anchors.right: removeHint.visible ? removeHint.left : weightText.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: String(rowItem.modelData.label || "")
                  color: rowItem.modelData.kind === "hint" ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: rowItem.modelData.kind === "question" || rowItem.modelData.best === true
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }

                Text {
                  width: parent.width
                  text: String(rowItem.modelData.detail || "")
                  visible: text !== ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                }
              }

              Text {
                id: weightText
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                visible: rowItem.modelData.kind === "ranked"
                width: visible ? implicitWidth : 0
                text: String(rowItem.modelData.detail || "")
                color: rowItem.modelData.best === true ? root.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: removeHint
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                visible: rowItem.modelData.kind === "attachment"
                text: "remove"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.selectedIndex = rowItem.index }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = rowItem.index
                  root.activate()
                }
              }
            }
          }

          // footer: a notice, or what the keys do
          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.font.caption + Style.space(2)

            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.mode === "ask"
                ? root.askFooter()
                : root.listFooter()
              color: root.noticeKind === "error" || (root.notice === "" && api.lastError !== "")
                ? root.urgent
                : (root.noticeKind === "ask" ? root.accent : root.dim)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }
          }
        }
      }

      // Standard app affordance: drag this corner to resize. Edges of a
      // borderless window are not hit-testable on their own, so the grip is
      // the visible target; Hyprland still resizes with its own bind too.
      Text {
        text: "◢"
        color: root.dim
        opacity: 0.55
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Style.space(4)

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(8)
          cursorShape: Qt.SizeFDiagCursor
          onPressed: panel.startSystemResize(Qt.RightEdge | Qt.BottomEdge)
        }
      }
    }
  }

  // A normal window, not another layer: the phone card is picked up and put
  // down like any app. It is separate so summoning the ask bar never replaces
  // a QR the user is still scanning.
  FloatingWindow {
    id: pairWindow
    title: "Reflex: pair"
    visible: root.pairOpen
    color: "transparent"
    implicitWidth: 380
    implicitHeight: 470
    minimumSize: Qt.size(340, 420)
    onVisibleChanged: { if (visible) pairFocusTimer.restart() }

    BorderSurface {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      FocusScope {
        id: pairFocus
        anchors.fill: parent
        focus: true

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.closePair(); event.accepted = true }
        }

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.space(8)

          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.font.caption + Style.space(8)

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton
              cursorShape: Qt.SizeAllCursor
              onPressed: pairWindow.startSystemMove()
            }

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "REFLEX"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "✕"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.closePair()
              }
            }
          }

          Text {
            Layout.fillWidth: true
            text: "Take Reflex with you"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            Layout.fillWidth: true
            text: "Scan with your phone’s camera. It signs you in, and your agents come along."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 228
            Layout.preferredHeight: 228

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: "white"
            }

            Image {
              anchors.fill: parent
              anchors.margins: Style.space(10)
              source: root.pairImage
              visible: root.pairImage !== ""
              fillMode: Image.PreserveAspectFit
              smooth: false
              cache: false
              asynchronous: true
            }

            Text {
              anchors.centerIn: parent
              visible: root.pairImage === ""
              text: root.pairError !== "" ? "No QR" : "Preparing…"
              color: "#333"
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            Layout.fillWidth: true
            text: root.pairPaired
              ? "Your phone is in. Add this page to your Home Screen."
              : (root.pairExpired
                ? "This code expired. Open /pair again for a new one."
                : (root.pairError !== "" ? root.pairError : "Waiting for the phone…"))
            color: root.pairPaired ? root.accent : (root.pairError !== "" ? root.urgent : root.dim)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            Layout.fillWidth: true
            visible: root.pairUrl !== ""
            text: root.pairUrl
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            Layout.fillWidth: true
            text: "One-time code, expires in 10 minutes. Pairing opens port 47823; the QR carries no token."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Item { Layout.fillHeight: true }

          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(34)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.foreground, root.accent)

            Text {
              anchors.centerIn: parent
              text: "Done"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.closePair()
            }
          }
        }
      }
    }
  }

  SettingsWindow {
    id: settingsWindow
    visible: root.settingsOpen
    initialSection: root.settingsSection
    onDismissed: root.settingsOpen = false
  }

  SetupWindow {
    id: setupWindow
    visible: root.setupOpen
    onDismissed: root.setupOpen = false
  }

  MachinesWindow {
    id: machinesWindow
    visible: root.machinesOpen
    onDismissed: root.machinesOpen = false
  }

  Instantiator {
    model: root.terminalOpen ? 1 : 0
    delegate: TerminalWindow {
      visible: true
      pane: root.terminalPane
      termTitle: root.terminalTitle
      onDismissed: root.terminalOpen = false
      onClosed: root.terminalOpen = false
      Component.onDestruction: {
        if (root.terminalOpen) root.terminalOpen = false
      }
    }
  }

  // The onboarding checks as a readable app window. The terminal helper stays
  // available for scripts; this is the menu-facing surface.
  FloatingWindow {
    id: doctorWindow
    title: "Reflex: doctor"
    visible: root.doctorOpen
    color: "transparent"
    implicitWidth: 460
    implicitHeight: 560
    minimumSize: Qt.size(380, 420)
    onVisibleChanged: { if (visible) doctorFocusTimer.restart() }

    BorderSurface {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      FocusScope {
        id: doctorFocus
        anchors.fill: parent
        focus: true

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.closeDoctor(); event.accepted = true }
        }

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.space(8)

          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.font.caption + Style.space(8)

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton
              cursorShape: Qt.SizeAllCursor
              onPressed: doctorWindow.startSystemMove()
            }

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "REFLEX"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "✕"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.closeDoctor()
              }
            }
          }

          Text {
            Layout.fillWidth: true
            text: "Readiness report"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            Layout.fillWidth: true
            text: "What this machine can do now, and what still needs an owner."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: doctorBody.height
            flickableDirection: Flickable.VerticalFlick

            Text {
              id: doctorBody
              width: parent.width
              text: root.doctorText
              color: root.doctorError !== "" ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(34)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.foreground, root.accent)

            Text {
              anchors.centerIn: parent
              text: "Done"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.closeDoctor()
            }
          }
        }
      }
    }
  }
}
