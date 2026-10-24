import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
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
  property string mode: "list"
  property string query: ""
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

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.mode = payload.mode === "ask" ? "ask" : "list"
    root.query = String(payload.query === undefined ? "" : payload.query)
    root.notice = ""
    root.ranked = []
    root.rankedFor = ""
    root.routing = false
    root.selectedIndex = 0
    root.cursorActive = false
    root.opened = true
    root.refresh()
    if (root.mode === "ask" && root.query !== "") searchTimer.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.cursorActive = false
  }

  function dismiss() {
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
    return "1 2 3 answer · enter open · / ask"
  }

  function askFooter() {
    if (api.lastError !== "") return api.lastError
    if (root.notice !== "") return root.notice
    return "enter routes · tab sessions · esc close"
  }

  function weight(bp) {
    return Math.round((Number(bp) || 0) / 100) + "%"
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
      for (var i = 0; i < root.ranked.length; i++) {
        var r = root.ranked[i]
        out.push({
          kind: "ranked",
          ranked: r,
          label: String(r.label || ""),
          detail: weight(r.bp),
          best: i === 0
        })
      }
      if (out.length === 0) {
        var text = root.query.trim()
        if (text === "") {
          out.push({ kind: "hint", label: "A few words find a session. A sentence goes to one." })
          out.push({ kind: "hint", label: "/claude /pi /codex pick the agent · /new starts in a new folder" })
          out.push({ kind: "hint", label: root.agents.length + " live sessions · " + root.questions.length + " waiting on you" })
        } else {
          out.push({ kind: "hint", label: root.rankedFor === text ? "Nothing matches." : "Searching…" })
        }
      }
      root.rows = out
      root.clampSelection()
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
      out.push({ kind: "update", item: update, label: String(update.title || "update"), detail: String(update.body || "") })
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

    if (row.kind === "option") {
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

  // ---------------------------------------------------------------- actions

  function answer(item, key) {
    if (!item) return
    api.post("/api/answer", JSON.stringify({ item: Number(item.id) || 0, key: String(key || "") }), "answer")
    root.say("answered " + String(key || ""))
  }

  // One place every routing action becomes an API call, so a new action kind in
  // daemon/Model.bend is one line here instead of a code path per view.
  function run(action, label) {
    if (!action || !action.type) return
    var type = String(action.type)
    if (type === "prompt") {
      api.post("/api/send", JSON.stringify({ pane: action.pane, text: action.text, label: label || "" }), "run")
    } else if (type === "spawn") {
      api.post("/api/spawn", JSON.stringify({ cwd: action.cwd, kind: action.kind, text: action.text }), "run")
    } else if (type === "resume") {
      api.post("/api/resume", JSON.stringify({ cwd: action.cwd, kind: action.kind, session: action.session, mode: action.mode, text: action.text }), "run")
    } else if (type === "press") {
      api.post("/api/keys", JSON.stringify({ pane: action.pane, key: action.key }), "run")
    } else if (type === "btw" || type === "fork") {
      api.post("/api/side", JSON.stringify({ pane: action.pane, text: action.text }), "run")
    } else {
      root.say("action this layer does not know: " + type, "error")
      return
    }
    root.say("→ " + String(label || type))
    closeTimer.restart()
  }

  // Send the typed request. reflexd returns the decision; when Jev is unsure we
  // show its options and never send anything on our own.
  function route() {
    var text = root.query.trim()
    if (text === "" || root.routing) return
    root.routing = true
    api.post("/api/route", JSON.stringify({ text: text }), "route")
  }

  function routeReply(json) {
    root.routing = false
    if (!json || json.ok !== true || !json.route) {
      root.say(json && json.error ? String(json.error) : "reflexd did not route that", "error")
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
    var text = root.query.trim()
    if (text === "") {
      root.ranked = []
      root.rankedFor = ""
      root.rebuild()
      return
    }
    api.post("/api/candidates", JSON.stringify({ text: text }), "candidates")
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
    if (tag === "candidates") {
      if (!json || json.ok !== true) {
        root.say(json && json.error ? String(json.error) : "search failed", "error")
        return
      }
      if (root.mode !== "ask") return
      root.ranked = listOf(json.ranked)
      root.rankedFor = root.query.trim()
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
      if (root.mode === "ask" && root.query !== "") root.editQuery("")
      else root.dismiss()
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
    if (code === Qt.Key_Return || code === Qt.Key_Enter) { root.activate(); event.accepted = true; return }
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
    if (text.length !== 1) { event.accepted = true; return }
    var ch = text.charCodeAt(0)
    if (ch < 32) { event.accepted = true; return }

    // 1, 2, 3 answer the question waiting on you: the same reflex as the
    // macOS rail. In the ask bar digits are only ever text.
    if (root.mode === "list" && ch >= 49 && ch <= 57) {
      if (root.answerWaiting(text)) { event.accepted = true; return }
    }
    if (root.mode === "list" && text === "/") {
      root.setMode("ask")
      event.accepted = true
      return
    }
    if (root.mode !== "ask") root.setMode("ask")
    root.editQuery(root.query + text)
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
    id: searchTimer
    interval: 260
    running: false
    repeat: false
    onTriggered: root.searchCandidates()
  }

  Timer {
    id: noticeTimer
    interval: 4000
    running: false
    repeat: false
    onTriggered: root.notice = ""
  }

  Timer {
    id: closeTimer
    interval: 700
    running: false
    repeat: false
    onTriggered: root.dismiss()
  }

  Api {
    id: api
    onReply: function(tag, json) { root.onReply(tag, json) }
    onTokenFailed: root.say("no API token. Run linux/install-omarchy.sh.", "error")
  }

  // -------------------------------------------------------------------- view

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "reflex"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Commons.Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(660), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(520), panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { root.onKey(event) }

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.space(10)

          // header: mode, counts, keys
          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.font.caption + Style.space(4)

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
              text: root.query === "" ? "Where should this go?" : root.query
              color: root.query === "" ? root.dim : root.foreground
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
                : root.statusColor(modelData.state)

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

              Column {
                id: rowText
                anchors.left: parent.left
                anchors.right: weightText.left
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
    }
  }
}
