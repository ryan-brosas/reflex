import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The macOS menu-bar icon, translated to an Omarchy bar slot: three dots for
// the states reflexd reports, a count for the questions waiting on you, a popup
// for the questions and the sessions, and the ask bar on right-click.
//
// A widget exists once per monitor and each instance owns its poller, so only
// the output Hyprland has focused polls quickly; the others read slowly rather
// than asking the same question seven times a second.
BarWidget {
  id: root
  moduleName: "reflex.sessions"

  property var state: ({})
  property var prefs: ({})
  property bool opened: false
  property bool railHovered: false
  // The macOS rail reserved a strip; default to the same 6 px. The setting
  // lives in one JSON file so the Settings window can change it without a
  // shell restart; REFLEX_RAIL_RESERVE=0 remains the installer override.
  readonly property bool reserveRail: prefs.railReserve !== false && (Quickshell.env("REFLEX_RAIL_RESERVE") || "1") !== "0"
  readonly property bool notifyEnabled: prefs.surfaceQuestions !== false
  readonly property bool keepAwake: prefs.keepAwake !== false
  readonly property string settingsFile: (Quickshell.env("XDG_CONFIG_HOME") || ((Quickshell.env("HOME") || "") + "/.config")) + "/reflex/settings.json"
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string sessionsHelper: home + "/.local/lib/reflex/bin/reflex-sessions"

  readonly property var agents: api.listOf(state.agents)
  readonly property var pending: api.listOf(state.pending)
  readonly property bool herdrOffline: state.herdr === false
  readonly property string startHerdrCommand: (Quickshell.env("HOME") || "") + "/.local/lib/reflex/bin/reflex-start-herdr"
  readonly property var inbox: api.listOf(state.inbox)
  readonly property var questions: questionsOf(inbox)
  readonly property var updates: updatesOf(inbox)
  readonly property int waiting: questions.length
  property var replyCache: ({})
  property int replyRevision: 0
  readonly property int working: countStatus("working")
  // On a vertical bar the rail belongs in the 6 px strip left of the bar, not
  // on top of it. On a horizontal bar it starts below the bar at the edge.
  readonly property real railTop: root.vertical ? 0 : root.barSize
  readonly property real railRight: root.vertical ? root.barSize : 0

  // A question waiting on you reaches the desktop, not just the bar. One
  // replaceable toast, raised by the focused output's widget only: every
  // monitor owns a copy of this widget and they poll independently. The
  // shell's notification helper carries the click action, so a toast never
  // steals focus by itself; clicking it summons the overlay.
  property int waitingSeen: -1
  property int toastId: 0
  onWaitingChanged: {
    if (!root.focusedScreen || !root.notifyEnabled) { waitingSeen = waiting; return }
    if (waitingSeen < 0) { waitingSeen = waiting; return }  // first read: no toast
    if (waiting > waitingSeen && !root.opened) root.notifyQuestions()
    else if (waiting === 0 && waitingSeen > 0) root.clearQuestions()
    waitingSeen = waiting
  }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.8)
  readonly property color borderColor: Commons.Color.popups.border
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool focusedScreen: {
    var monitor = Hyprland.focusedMonitor
    var window = root.QsWindow.window
    if (!monitor || !window || !window.screen) return true
    return String(monitor.name || "") === String(window.screen.name || "")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function open() { opened = true }
  function close() { opened = false }
  function toggle() { opened ? close() : open() }

  function readPrefs(raw) {
    var parsed = ({})
    try { parsed = JSON.parse(String(raw || "{}")) } catch (e) { parsed = ({}) }
    root.prefs = parsed
  }

  function openSettings() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{\"settings\":true}"])
    close()
  }

  function openPair() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{\"pair\":true}"])
    close()
  }

  function openDoctor() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{\"doctor\":true}"])
    close()
  }

  function openMachines() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{\"machines\":true}"])
    close()
  }

  function restartDaemon() {
    Quickshell.execDetached(["systemctl", "--user", "restart", "reflexd.service"])
    close()
  }

  function openLog() {
    Quickshell.execDetached(["xdg-terminal-exec", "journalctl", "--user", "-u", "reflexd", "-f"])
    close()
  }

  function undoLast() {
    var last = root.pending.length > 0 ? root.pending[0] : null
    if (!last) return
    api.post("/api/cancel", JSON.stringify({ id: Number(last.id) || 0 }), "cancel")
    close()
  }

  function footerAction(action) {
    if (action === "ask") root.askBar()
    else if (action === "settings") root.openSettings()
    else if (action === "phone") root.openPair()
    else if (action === "doctor") root.openDoctor()
    else if (action === "machines") root.openMachines()
    else if (action === "clear") root.clearUpdates()
    else if (action === "restart") root.restartDaemon()
    else if (action === "log") root.openLog()
  }

  function countStatus(status) {
    var n = 0
    for (var i = 0; i < agents.length; i++)
      if (String(agents[i].status || "") === status) n += 1
    return n
  }

  function questionsOf(items) {
    var out = []
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (!item || String(item.kind || "") !== "ask") continue
      if (api.listOf(item.options).length === 0) continue
      out.push(item)
    }
    return out
  }

  function updatesOf(items) {
    var out = []
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (!item || String(item.kind || "") === "ask") continue
      out.push(item)
    }
    out.sort(function (a, b) { return (Number(b.at) || 0) - (Number(a.at) || 0) })
    return out
  }

  // The Mac inbox showed the end of a screen as prose when no session reply
  // was available. Keep the same shape: strip the terminal chrome, join the
  // wrapped lines, and show the last few paragraphs.
  function gist(body) {
    var raw = String(body || "").split("\n")
    var out = []
    var current = ""
    function flush() {
      if (current !== "") out.push(current)
      current = ""
    }
    for (var i = 0; i < raw.length; i++) {
      var line = raw[i]
      var text = line.trim()
      if (text === "" || /^[\s─━═—\-_│┃╭╮╰╯┌┐└┘├┤┬┴┼]+$/.test(text)) { flush(); continue }
      if (text === "❯" || text === ">" || text === "›" || text === "$") { flush(); continue }
      if (/^[*✻✽✶✳✢·⏵⎿]\s*\S+ for \d/.test(text)) { flush(); continue }
      if (text.indexOf("esc to interrupt") >= 0 || text.indexOf("? for shortcuts") >= 0 ||
          text.indexOf("bypass permissions") >= 0 || text.indexOf("accept edits") >= 0) { flush(); continue }
      var marks = ["⏺ ", "● ", "• "]
      for (var m = 0; m < marks.length; m++)
        if (text.indexOf(marks[m]) === 0) text = text.substring(marks[m].length)
      if (current !== "" && (line.charAt(0) === " " || current.charAt(current.length - 1) !== "."))
        current += " " + text
      else {
        flush()
        current = text
      }
    }
    flush()
    var tail = out.slice(Math.max(0, out.length - 3)).join("\n")
    return tail.length > 600 ? tail.substring(0, 600) : tail
  }

  function agentFor(pane) {
    var wanted = String(pane || "")
    if (wanted === "") return null
    for (var i = 0; i < root.agents.length; i++)
      if (String(root.agents[i].pane || "") === wanted) return root.agents[i]
    return null
  }

  function replyFor(row) {
    var item = row && row.item ? row.item : row
    if (!item) return ""
    var id = Number(item.id) || 0
    if (root.replyCache[id] !== undefined)
      return String(root.replyCache[id] || root.gist(item.body))
    return root.gist(item.body)
  }

  function ensureReply() {
    if (!root.opened) return
    var row = root.rows[list.cursorIndex]
    if (!row || row.kind !== "update") return
    root.ensureReplyFor(row.item)
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
    for (var i = 0; i < root.updates.length; i++) {
      root.ensureReplyFor(root.updates[i])
      if (replyProcess.running) return
    }
  }


  function leaf(path) {
    var parts = String(path || "").split("/")
    for (var i = parts.length - 1; i >= 0; i--) if (parts[i] !== "") return parts[i]
    return "~"
  }

  function agentLabel(agent) {
    var name = String(agent.name || "")
    if (name === "") name = String(agent.kind || "agent")
    return name + " · " + leaf(agent.cwd)
  }

  function statusWord(status) {
    var s = String(status || "")
    if (s === "blocked") return "waits on you"
    if (s === "working") return "working"
    return s === "done" ? "done" : "idle"
  }

  function statusColor(status) {
    var s = String(status || "")
    if (s === "blocked") return urgent
    if (s === "working") return accent
    return dim
  }

  function answer(item, key) {
    if (!item) return
    api.post("/api/answer", JSON.stringify({ item: Number(item.id) || 0, key: String(key || "") }), "answer")
  }

  function focusAgent(agent) {
    api.post("/api/focus", JSON.stringify({ pane: String(agent.pane || "") }), "focus")
    close()
  }

  function focusPane(pane) {
    var value = String(pane || "")
    if (value === "") return
    api.post("/api/focus", JSON.stringify({ pane: value }), "focus")
    close()
  }

  function dismissItem(item) {
    if (!item) return
    api.post("/api/dismiss", JSON.stringify({ item: Number(item.id) || 0 }), "dismiss")
  }

  function clearUpdates() {
    for (var i = 0; i < root.updates.length; i++) root.dismissItem(root.updates[i])
  }

  // herdr is a separately owned server. Reflex reports it and starts it the
  // native way (a terminal running herdr); it never supervises it.
  function startHerdr() {
    Quickshell.execDetached([root.startHerdrCommand])
    close()
  }

  function askBar() {
    Quickshell.execDetached(["omarchy-shell", "-q", "shell", "summon", "reflex", "{\"mode\":\"ask\"}"])
    close()
  }

  function notifyQuestions() {
    var first = root.questions.length > 0 ? root.questions[0] : null
    var title = root.waiting === 1 ? "Reflex · 1 question waiting" : "Reflex · " + root.waiting + " questions waiting"
    var body = first ? String(first.title || first.body || "a question").split("\n")[0] : "Open Reflex to answer."
    var command = ["omarchy", "notification", "send", "-p", "--app-name", "Reflex", "-u", "normal"]
    if (root.toastId > 0) command = command.concat(["-r", String(root.toastId)])
    command = command.concat([title, body, "--exec", "omarchy-shell", "shell", "summon", "reflex.sessions", "{}"])
    toast.command = command
    toast.running = true
  }

  function clearQuestions() {
    root.toastId = 0
    Quickshell.execDetached(["omarchy", "notification", "dismiss", "Reflex"])
  }

  // Open the overlay's embedded terminal window on the agent's pane. Herdr
  // owns the PTY; the overlay observes its terminal stream and sends input.
  function attachAgent(agent) {
    if (!agent) return
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", JSON.stringify({
      terminal: String(agent.pane || ""),
      terminalTitle: String(agent.title || agent.name || "")
    })])
    close()
  }

  // Blocked first, then working, then the rest: the same order the overlay uses.
  function buildRows() {
    var out = []
    if (root.herdrOffline) {
      out.push({ kind: "offline", label: "herdr isn't running", detail: "click to start" })
      return out
    }
    for (var q = 0; q < questions.length; q++) {
      var item = questions[q]
      var options = api.listOf(item.options)
      for (var o = 0; o < options.length; o++) {
        out.push({
          kind: "option",
          item: item,
          key: String(options[o].key || ""),
          label: String(options[o].label || "") + "  ·  " + String(item.body || "").split("\n")[0]
        })
      }
    }
    for (var u = 0; u < root.updates.length; u++) {
      var update = root.updates[u]
      out.push({
        kind: "update",
        item: update,
        label: String(update.agent || "reflex") + " · " + String(update.title || "update")
      })
    }
    var ordered = agents.slice()
    var rank = { blocked: 0, working: 1, done: 2, idle: 3, unknown: 4 }
    ordered.sort(function(x, y) {
      var rx = rank[String(x.status || "unknown")]
      var ry = rank[String(y.status || "unknown")]
      if (rx === undefined) rx = 4
      if (ry === undefined) ry = 4
      if (rx !== ry) return rx - ry
      return (Number(y.seq) || 0) - (Number(x.seq) || 0)
    })
    for (var p = 0; p < root.pending.length; p++) {
      var dispatch = root.pending[p]
      out.push({
        kind: "pending",
        dispatch: dispatch,
        label: String(dispatch.label || "dispatch"),
        detail: "in " + Math.max(0, Math.round((Number(dispatch.left) || 0) / 1000)) + "s · u undoes"
      })
    }
    for (var a = 0; a < ordered.length; a++) {
      out.push({
        kind: "agent",
        agent: ordered[a],
        label: agentLabel(ordered[a]),
        detail: statusWord(ordered[a].status)
      })
    }
    if (out.length === 0) out.push({ kind: "hint", label: "No live sessions" })
    return out
  }

  readonly property var rows: buildRows()

  function onReply(tag, json) {
    if (api.lastError.indexOf("401") >= 0) {
      api.reauth()
      return
    }
    if (tag === "state") {
      if (json && (json.agents !== undefined || json.now !== undefined)) state = json
      return
    }
    if (tag === "answer" || tag === "focus" || tag === "dismiss") api.get("/api/state", "state")
  }

  onOpenedChanged: {
    if (!opened) return
    api.get("/api/state", "state")
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
      root.ensureReply()
    })
  }

  Api {
    id: api
    onReply: function(tag, json) { root.onReply(tag, json) }
  }

  Timer {
    id: replyTimer
    interval: 1500
    repeat: true
    running: root.opened && root.updates.length > 0
    onTriggered: root.refreshReplies()
  }

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
        var text = ""
        try {
          var parsed = JSON.parse(String(replyOut.text || "{}"))
          if (parsed && parsed.ok === true) text = String(parsed.reply || "")
        } catch (e) {
          text = ""
        }
        root.replyCache[id] = text
        root.replyRevision += 1
      }
      replyProcess.itemId = 0
    }
  }

  FileView {
    id: prefsFile
    path: root.settingsFile
    watchChanges: true
    preload: true
    onTextChanged: root.readPrefs(text())
  }

  // Keep the session awake while an agent is working. Only the focused
  // output's widget holds the inhibitor, so seven monitors do not hold seven.
  // systemd-inhibit --what=idle is the desktop-owned mechanism; no Reflex
  // daemon change is needed.
  Process {
    id: keepAwake
    running: root.working > 0 && root.keepAwake && root.focusedScreen
    command: ["systemd-inhibit", "--what=idle", "--who=Reflex", "--why=coding agent is working", "--mode=block", "sleep", "infinity"]
  }

  // `omarchy notification send -p` prints the toast id; `-r` replaces that toast
  // on the next question instead of stacking a second one. Capturing the id
  // matters: dismissing alongside a send races it and can wipe the new toast
  // before anyone sees it.
  Process {
    id: toast
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var id = parseInt(String(text).trim())
        if (id > 0) root.toastId = id
      }
    }
  }

  Timer {
    interval: root.opened ? 1500 : (root.focusedScreen ? 3000 : 15000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: api.get("/api/state", "state")
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: {
      if (root.herdrOffline) return "herdr isn't running · click to start"
      if (root.questions.length > 0) return root.questions.length + (root.questions.length === 1 ? " question waiting" : " questions waiting") + " · right-click asks"
      if (root.working > 0) return root.working + (root.working === 1 ? " agent working" : " agents working") + " · " + root.agents.length + " sessions · right-click asks"
      if (root.agents.length > 0) return root.agents.length + " sessions · right-click asks"
      return "Reflex · right-click asks"
    }
    iconComponent: Component {
      Item {
        // The host fills this component to Style.bar.iconCanvas. A glyph is the
        // bar's own language; the amber count replaces it when questions wait,
        // which is the one thing the herdr widget beside it does not answer.
        Text {
          anchors.centerIn: parent
          visible: root.questions.length === 0
          text: "󰋗"
          color: root.herdrOffline ? root.dim : (root.working > 0 ? root.accent : root.foreground)
          opacity: root.herdrOffline ? 0.5 : (root.agents.length > 0 ? 1 : 0.45)
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }

        Rectangle {
          visible: root.questions.length > 0
          anchors.centerIn: parent
          width: Math.max(Style.space(16), countText.implicitWidth + Style.space(6))
          height: Style.space(16)
          radius: height / 2
          color: root.urgent

          Text {
            id: countText
            anchors.centerIn: parent
            text: root.questions.length > 9 ? "9+" : String(root.questions.length)
            color: Commons.Color.popups.background
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.askBar()
      else if (root.herdrOffline) root.startHerdr()
      else root.toggle()
    }
  }

  // The macOS edge rail, translated as a real layer surface: a 6 px tab on
  // the right edge of this output that widens on hover to a compact summary.
  // It does not reserve an exclusive strip (that would shift every window);
  // clicking it opens the full bar panel, which owns keyboard input.
  PanelWindow {
    id: rail
    screen: root.QsWindow && root.QsWindow.window ? root.QsWindow.window.screen : null
    anchors { top: true; bottom: true; right: true }
    margins { top: root.railTop; right: root.railRight }
    implicitWidth: root.railHovered ? Style.space(286) : 6
    color: "transparent"
    surfaceFormat.opaque: false
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "reflex-rail"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    Behavior on implicitWidth { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.background
      border.width: root.railHovered ? Math.max(1, Style.space(1)) : 0
      border.color: Style.space(1) > 0 ? root.borderColor : "transparent"
      clip: true
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: Style.space(3)
      radius: width / 2
      color: root.questions.length > 0 ? root.urgent : (root.working > 0 ? root.accent : root.dim)
      opacity: root.railHovered ? 0 : 0.9
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onEntered: root.railHovered = true
      onExited: root.railHovered = false
      onClicked: root.toggle()
    }

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(16)
      spacing: Style.space(10)
      visible: root.railHovered
      opacity: root.railHovered ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }

      Text {
        text: "REFLEX"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.2
      }

      Text {
        width: parent.width
        text: {
          if (root.herdrOffline) return "herdr isn't running"
          if (root.questions.length > 0) return root.questions.length + (root.questions.length === 1 ? " question waiting" : " questions waiting")
          if (root.working > 0) return root.working + " working"
          return root.agents.length + " sessions"
        }
        color: root.questions.length > 0 ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        wrapMode: Text.WordWrap
      }

      Rectangle {
        width: parent.width
        height: Math.max(1, Style.space(1))
        color: root.borderColor
        opacity: 0.7
      }

      // The Mac rail's dots: one per live agent, blocked first. Clicking a dot
      // focuses that pane; the 6 px tab itself stays a quiet status line.
      Flow {
        width: parent.width
        spacing: Style.space(6)
        Repeater {
          model: root.agents.slice(0, 12)
          Rectangle {
            width: Style.space(8)
            height: width
            radius: width / 2
            color: root.statusColor(modelData.status)
            opacity: modelData.status === "idle" ? 0.5 : 1
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.focusAgent(modelData)
            }
          }
        }
      }

      // One question card, with its real options, so the rail can answer the
      // same way the bar panel can. The options come from reflexd, not a copy.
      Rectangle {
        visible: root.questions.length > 0
        width: parent.width
        height: questionColumn.implicitHeight + Style.space(16)
        radius: Style.cornerRadius
        color: Style.selectedFillFor(root.foreground, root.urgent)
        border.width: 1
        border.color: root.urgent
        opacity: 0.95

        Column {
          id: questionColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(8)
          spacing: Style.space(4)

          Text {
            width: parent.width
            text: root.questions.length > 0 ? String(root.questions[0].title || "a question") : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }
          Text {
            width: parent.width
            visible: text !== ""
            text: root.questions.length > 0 ? String(root.questions[0].body || "").split("\n")[0] : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
          Repeater {
            model: root.questions.length > 0 ? api.listOf(root.questions[0].options).slice(0, 4) : []
            Item {
              width: parent.width
              height: Style.space(20)
              Rectangle {
                width: Style.space(16)
                height: width
                radius: Style.space(3)
                anchors.verticalCenter: parent.verticalCenter
                color: Style.selectedFillFor(root.foreground, root.accent)
                Text {
                  anchors.centerIn: parent
                  text: String(modelData.key || "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(22)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.label || "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.answer(root.questions[0], modelData.key)
              }
            }
          }
        }
      }

      Repeater {
        model: root.agents.slice(0, 4)
        Item {
          width: parent.width
          height: Style.space(20)
          Rectangle {
            width: Style.space(6)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.statusColor(modelData.status)
          }
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(12)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.agentLabel(modelData)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.focusAgent(modelData)
          }
        }
      }

      Text {
        width: parent.width
        text: root.agents.length + " live · click a dot to focus · right-click asks"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  // Fixed 6 px reservation, separate from the animated hover surface. A
  // Normal exclusion here reserves the strip once; the visual rail above can
  // still widen to 286 px without shifting every window on hover.
  PanelWindow {
    id: railReserve
    visible: root.reserveRail
    screen: root.QsWindow && root.QsWindow.window ? root.QsWindow.window.screen : null
    anchors { top: true; bottom: true; right: true }
    // An exclusive layer is already placed left of the bar's own exclusive
    // zone; adding the bar width again would reserve a second, empty strip.
    margins { top: root.railTop }
    implicitWidth: 6
    color: "transparent"
    exclusiveZone: 6
    exclusionMode: ExclusionMode.Normal
    WlrLayershell.namespace: "reflex-rail-reserve"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(420))

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var code = event.key
        if (code === Qt.Key_Escape) { root.close(); event.accepted = true; return }
        if (code === Qt.Key_Down) { list.move(1); event.accepted = true; return }
        if (code === Qt.Key_Up) { list.move(-1); event.accepted = true; return }
        if (code === Qt.Key_Return || code === Qt.Key_Enter) {
          if ((event.modifiers & Qt.ShiftModifier) !== 0 && list.shiftActivate()) { event.accepted = true; return }
          list.activate(); event.accepted = true; return
        }
        var text = String(event.text || "")
        if ((text === "e" || text === "E") && list.dismissSelected()) {
          event.accepted = true
          return
        }
        if ((text === "u" || text === "U") && root.pending.length > 0) {
          root.undoLast()
          event.accepted = true
          return
        }
        if (text.length === 1 && text.charCodeAt(0) >= 49 && text.charCodeAt(0) <= 57 && root.questions.length > 0) {
          var first = root.questions[0]
          var options = api.listOf(first.options)
          for (var i = 0; i < options.length; i++)
            if (String(options[i].key || "") === text) root.answer(first, text)
          event.accepted = true
          return
        }
        event.accepted = true
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(6)

        Item {
          width: parent.width
          implicitHeight: Style.font.title + Style.space(6)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - (askHint.visible ? askHint.width + Style.space(8) : 0)
            text: {
              if (root.herdrOffline) return "herdr isn't running"
              if (root.questions.length > 0) return root.questions.length + " waiting on you"
              if (root.updates.length > 0) return root.updates.length + (root.updates.length === 1 ? " update" : " updates")
              if (root.working > 0) return root.working + " working"
              if (root.agents.length > 0) return root.agents.length + " sessions"
              return "Reflex"
            }
            color: root.questions.length > 0 ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }

          Text {
            id: askHint
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: text !== ""
            text: "right-click asks"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        ListView {
          id: list
          width: parent.width
          height: Math.min(contentHeight, Style.space(340))
          clip: true
          spacing: Style.space(2)
          boundsBehavior: Flickable.StopAtBounds
          model: root.rows

          property int cursorIndex: 0
          property bool cursorActive: false

          onCursorIndexChanged: root.ensureReply()
          onCountChanged: {
            if (cursorIndex >= count) cursorIndex = Math.max(0, count - 1)
            root.ensureReply()
          }

          function move(delta) {
            if (root.rows.length === 0) return
            cursorActive = true
            cursorIndex = (cursorIndex + delta + root.rows.length) % root.rows.length
            positionViewAtIndex(cursorIndex, ListView.Contain)
            root.ensureReply()
          }

          function activate() {
            var row = root.rows[cursorIndex]
            if (!row) return
            if (row.kind === "offline") root.startHerdr()
            else if (row.kind === "option") root.answer(row.item, row.key)
            else if (row.kind === "update") root.focusPane(row.item ? row.item.pane : "")
            else if (row.kind === "pending") root.undoLast()
            else if (row.kind === "agent") root.focusAgent(row.agent)
          }

          function dismissSelected() {
            var row = root.rows[cursorIndex]
            if (!row || !row.item) return false
            if (row.kind !== "update" && row.kind !== "option") return false
            root.dismissItem(row.item)
            return true
          }

          function shiftActivate() {
            var row = root.rows[cursorIndex]
            if (!row || row.kind !== "agent") return false
            root.attachAgent(row.agent)
            return true
          }

          delegate: Item {
            required property var modelData
            required property int index

            readonly property bool selected: list.cursorActive && list.cursorIndex === index
            readonly property color tone: modelData.kind === "agent"
              ? root.statusColor(modelData.agent ? modelData.agent.status : "")
              : (modelData.kind === "option" ? root.urgent : (modelData.kind === "update" ? root.accent : root.dim))

            width: ListView.view ? ListView.view.width : 0
            height: Math.max(Style.space(26), textColumn.implicitHeight + Style.spacing.controlPaddingY)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Style.selectedFillFor(root.foreground, tone)
              opacity: selected ? 0.9 : 0
            }

            Rectangle {
              width: Style.space(2)
              height: parent.height - Style.space(8)
              anchors.left: parent.left
              anchors.leftMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              radius: 1
              color: tone
              opacity: modelData.kind === "hint" ? 0 : (selected ? 1 : 0.55)
            }

            Column {
              id: textColumn
              anchors.left: parent.left
              anchors.right: keyHint.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              spacing: 2

              Text {
                id: label
                width: parent.width
                text: String(modelData.label || "")
                color: modelData.kind === "hint" ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }

              Text {
                id: detailText
                width: parent.width
                visible: modelData.kind === "update"
                text: {
                  var revision = root.replyRevision
                  return root.replyFor(modelData)
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }

            Text {
              id: keyHint
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.kind === "update" ? "e" : String(modelData.key || (modelData.detail || ""))
              visible: text !== ""
              color: modelData.kind === "option" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                enabled: modelData.kind === "update"
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.dismissItem(modelData)
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: { list.cursorActive = true; list.cursorIndex = index }
              onClicked: { list.cursorActive = true; list.cursorIndex = index; list.activate() }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Math.max(1, Style.space(1))
          color: root.borderColor
          opacity: 0.45
        }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Repeater {
            model: root.updates.length > 0
              ? ["ask", "settings", "phone", "doctor", "machines", "clear", "restart", "log"]
              : ["ask", "settings", "phone", "doctor", "machines", "restart", "log"]
            Text {
              text: modelData
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.footerAction(modelData)
              }
            }
          }
        }
      }
    }
  }
}
