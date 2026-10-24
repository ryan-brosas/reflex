import QtQuick
import Quickshell
import Quickshell.Hyprland
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
  property bool opened: false

  readonly property var agents: api.listOf(state.agents)
  readonly property var inbox: api.listOf(state.inbox)
  readonly property var questions: questionsOf(inbox)
  readonly property int waiting: questions.length
  readonly property int working: countStatus("working")

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.8)
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

  function askBar() {
    Quickshell.execDetached(["omarchy-shell", "-q", "shell", "summon", "reflex", "{\"mode\":\"ask\"}"])
    close()
  }

  // Blocked first, then working, then the rest: the same order the overlay uses.
  function buildRows() {
    var out = []
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
    if (tag === "state") {
      if (json && (json.agents !== undefined || json.now !== undefined)) state = json
      return
    }
    if (tag === "answer" || tag === "focus") api.get("/api/state", "state")
  }

  onOpenedChanged: {
    if (!opened) return
    api.get("/api/state", "state")
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Api {
    id: api
    onReply: function(tag, json) { root.onReply(tag, json) }
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
    iconComponent: Component {
      Item {
        implicitWidth: Style.space(24)
        implicitHeight: Style.space(16)

        Row {
          anchors.centerIn: parent
          spacing: Style.space(3.5)

          Rectangle {
            width: Style.space(5)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.questions.length > 0 ? root.urgent : root.dim
            opacity: root.questions.length > 0 ? 1 : 0.4
          }
          Rectangle {
            width: Style.space(5)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.working > 0 ? root.accent : root.dim
            opacity: root.working > 0 ? 1 : 0.4
          }
          Rectangle {
            width: Style.space(5)
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: root.dim
            opacity: root.agents.length > 0 ? 0.6 : 0.2
          }
        }

        Text {
          visible: root.questions.length > 0
          anchors.left: parent.right
          anchors.leftMargin: -Style.space(3)
          anchors.bottom: parent.top
          anchors.bottomMargin: -Style.space(4)
          text: String(root.questions.length)
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.askBar()
      else root.toggle()
    }
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
        if (code === Qt.Key_Return || code === Qt.Key_Enter) { list.activate(); event.accepted = true; return }
        var text = String(event.text || "")
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
              if (root.questions.length > 0) return root.questions.length + " waiting on you"
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

          function move(delta) {
            if (root.rows.length === 0) return
            cursorActive = true
            cursorIndex = (cursorIndex + delta + root.rows.length) % root.rows.length
            positionViewAtIndex(cursorIndex, ListView.Contain)
          }

          function activate() {
            var row = root.rows[cursorIndex]
            if (!row) return
            if (row.kind === "option") root.answer(row.item, row.key)
            else if (row.kind === "agent") root.focusAgent(row.agent)
          }

          delegate: Item {
            required property var modelData
            required property int index

            readonly property bool selected: list.cursorActive && list.cursorIndex === index
            readonly property color tone: modelData.kind === "agent"
              ? root.statusColor(modelData.agent ? modelData.agent.status : "")
              : (modelData.kind === "option" ? root.urgent : root.dim)

            width: ListView.view ? ListView.view.width : 0
            height: Math.max(Style.space(26), label.implicitHeight + Style.spacing.controlPaddingY)

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

            Text {
              id: label
              anchors.left: parent.left
              anchors.right: keyHint.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              text: String(modelData.label || "")
              color: modelData.kind === "hint" ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }

            Text {
              id: keyHint
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: String(modelData.key || (modelData.detail || ""))
              visible: text !== ""
              color: modelData.kind === "option" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
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
      }
    }
  }
}
