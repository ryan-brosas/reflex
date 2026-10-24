import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Terminal.js" as Term

// A real embedded view over herdr's terminal stream.
//
// herdr owns the PTY. This window renders the ANSI control stream and sends
// input, resize, scroll and mouse commands back over the same control channel,
// so it never becomes a second terminal emulator with its own process. The
// external terminal remains available for full-screen apps and IME.
FloatingWindow {
  id: root
  property string pane: ""
  property string termTitle: "Terminal"
  property string status: "idle"
  property string terminalId: ""
  property var termScreen: null
  property string historyText: ""
  property string historyStatus: ""
  property bool historyOpen: false
  property string imePreedit: ""
  signal dismissed()

  title: "Reflex: " + (root.termTitle || "terminal")
  color: "transparent"
  implicitWidth: 980
  implicitHeight: 640
  minimumSize: Qt.size(520, 360)

  onVisibleChanged: {
    if (visible) {
      focusTimer.tries = 0
      root.start()
    } else root.stop()
  }

  function start() {
    if (root.pane === "") { root.status = "no pane"; return }
    root.termScreen = Term.createScreen(80, 24)
    root.status = "connecting"
    root.terminalId = ""
    root.historyText = ""
    root.historyStatus = ""
    root.historyOpen = false
    root.imePreedit = ""
    terminalIme.clear()
    terminalControl.running = false
    launchTimer.restart()
    focusTimer.restart()
  }

  function stop() {
    paneGet.running = false
    terminalControl.running = false
    root.status = "idle"
    root.termScreen = null
    root.imePreedit = ""
    terminalIme.clear()
    terminalCanvas.requestPaint()
  }

  function close() {
    root.historyOpen = false
    root.visible = false
    root.dismissed()
  }

  function rowText(cells, cols, y) {
    var line = ""
    for (var x = 0; x < cols; x++) {
      var cell = cells[y * cols + x]
      if (!cell || cell.cont) continue
      line += String(cell.ch || " ")
    }
    return line.replace(/\s+$/, "")
  }

  function localHistoryText() {
    var term = root.termScreen
    if (!term) return ""
    var lines = []
    var history = term.history || []
    for (var h = 0; h < history.length; h++) {
      var line = root.rowText(history[h], term.cols, 0)
      if (line !== "") lines.push(line)
    }
    for (var y = 0; y < term.rows; y++) {
      var current = root.rowText(term.cells, term.cols, y)
      if (current !== "") lines.push(current)
    }
    while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()
    return lines.join("\n")
  }

  function scrollHistory(delta) {
    var max = Math.max(0, historyFlick.contentHeight - historyFlick.height)
    historyFlick.contentY = Math.max(0, Math.min(max, historyFlick.contentY + delta))
  }

  function openHistory() {
    if (root.pane === "" || historyProcess.running) return
    var local = root.localHistoryText()
    if (local !== "") {
      root.historyText = local
      root.historyStatus = ""
      root.historyOpen = true
      Qt.callLater(function() { historyFlick.contentY = Math.max(0, historyFlick.contentHeight - historyFlick.height) })
      return
    }
    root.historyStatus = "loading history…"
    historyProcess.command = ["herdr", "pane", "read", root.pane, "--source", "recent", "--lines", "400", "--format", "text"]
    historyProcess.running = true
  }

  function historyReady(text, code) {
    if (Number(code) === 0) {
      root.historyText = String(text || "").trim()
      root.historyStatus = root.historyText === "" ? "no recent history" : ""
    } else {
      root.historyText = "history unavailable"
      root.historyStatus = ""
    }
    root.historyOpen = true
  }

  function paneReady(text, code) {
    if (Number(code) !== 0) { root.status = "pane lookup failed"; return }
    var reply = {}
    try { reply = JSON.parse(String(text || "{}")) } catch (e) { reply = {} }
    var pane = reply.result && reply.result.pane ? reply.result.pane : null
    if (!pane || !pane.terminal_id) { root.status = "pane has no terminal"; return }
    root.terminalId = String(pane.terminal_id)
    root.status = "live"
    root.startControl()
    focusTimer.tries = 0
    focusTimer.restart()
  }

  function readFrame(line) {
    var text = String(line || "").trim()
    if (text === "" || !root.visible) return
    var frame = {}
    try { frame = JSON.parse(text) } catch (e) { return }
    if (frame.type !== "terminal.frame" || !frame.bytes) return
    var width = Number(frame.width) || 80
    var height = Number(frame.height) || 24
    if (frame.full || !root.termScreen || root.termScreen.cols !== width || root.termScreen.rows !== height)
      root.termScreen = Term.createScreen(width, height)
    try { Term.feed(root.termScreen, Term.decode(String(frame.bytes))) }
    catch (e) { root.status = "terminal parse: " + e }
    terminalCanvas.requestPaint()
  }

  function writeControl(command) {
    if (!terminalControl.running) return false
    try {
      terminalControl.write(JSON.stringify(command) + "\n")
      return true
    } catch (e) {
      return false
    }
  }

  function startControl() {
    if (root.terminalId === "") return
    var cols = root.gridColumns()
    var rows = root.gridRows()
    terminalControl.command = ["herdr", "terminal", "session", "control", root.terminalId,
      "--cols", String(cols), "--rows", String(rows)]
    terminalControl.running = true
    resizeTimer.restart()
  }

  function gridColumns() {
    if (!terminalCanvas || terminalCanvas.width <= 0) return 80
    return Math.max(20, Math.floor(terminalCanvas.width / Math.max(6, Style.font.body * 0.62)))
  }

  function gridRows() {
    if (!terminalCanvas || terminalCanvas.height <= 0) return 24
    return Math.max(6, Math.floor(terminalCanvas.height / Math.max(12, Style.font.body * 1.25)))
  }

  function requestResize() {
    if (root.visible && root.terminalId !== "") resizeTimer.restart()
  }

  function resizeControl() {
    if (!terminalControl.running) return
    var cols = root.gridColumns()
    var rows = root.gridRows()
    if (root.termScreen && root.termScreen.cols === cols && root.termScreen.rows === rows) return
    root.writeControl({ type: "terminal.resize", cols: cols, rows: rows })
  }

  function sendText(value) {
    var text = String(value === undefined ? "" : value)
    if (text === "" || root.pane === "") return
    if (root.writeControl({ type: "terminal.input", text: text })) return
    Quickshell.execDetached(["herdr", "pane", "send-text", root.pane, text])
  }

  function sendKey(name) {
    if (root.pane === "") return
    var cursor = (root.termScreen && root.termScreen.appCursor) ? "\u001bO" : "\u001b["
    var sequences = {
      "Enter": "\r", "Backspace": "\u007f", "Tab": "\t", "Escape": "\u001b",
      "Up": cursor + "A", "Down": cursor + "B", "Right": cursor + "C", "Left": cursor + "D",
      "Home": cursor + "H", "End": cursor + "F",
      "PageUp": "\u001b[5~", "PageDown": "\u001b[6~",
      "Delete": "\u001b[3~", "Insert": "\u001b[2~"
    }
    if (sequences[name] !== undefined && root.writeControl({ type: "terminal.input", text: sequences[name] })) return
    Quickshell.execDetached(["herdr", "pane", "send-keys", root.pane, String(name)])
  }

  function mouseModifiers(mods) {
    var value = 0
    if (mods & Qt.ShiftModifier) value |= 1
    if (mods & Qt.ControlModifier) value |= 2
    if (mods & Qt.AltModifier) value |= 4
    return value
  }

  function mouseCellX(x) {
    var cols = root.termScreen ? root.termScreen.cols : 80
    var width = terminalCanvas.width
    if (width <= 0) return 0
    return Math.max(0, Math.min(cols - 1, Math.floor(Number(x) / (width / cols))))
  }

  function mouseCellY(y) {
    var rows = root.termScreen ? root.termScreen.rows : 24
    var height = terminalCanvas.height
    if (height <= 0) return 0
    return Math.max(0, Math.min(rows - 1, Math.floor(Number(y) / (height / rows))))
  }

  function mouseButton(button) {
    if (button === Qt.RightButton) return "right"
    if (button === Qt.MiddleButton) return "middle"
    return "left"
  }

  function sendMouse(action, button, x, y, mods) {
    root.writeControl({
      type: "terminal.mouse", action: action, button: root.mouseButton(button),
      column: root.mouseCellX(x), row: root.mouseCellY(y), modifiers: root.mouseModifiers(mods)
    })
  }

  function sendScroll(direction, x, y, mods) {
    root.writeControl({
      type: "terminal.scroll", direction: direction, lines: 1, source: "wheel",
      column: root.mouseCellX(x), row: root.mouseCellY(y), modifiers: root.mouseModifiers(mods)
    })
  }

  function openExternal() {
    root.stop()
    root.visible = false
    root.dismissed()
    Quickshell.execDetached(["omarchy-launch-terminal", "herdr", "agent", "attach", root.pane])
  }

  function controlCode(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return key - Qt.Key_A + 1
    if (key === Qt.Key_Space) return 0
    if (key === Qt.Key_BracketLeft) return 27
    if (key === Qt.Key_Backslash) return 28
    if (key === Qt.Key_BracketRight) return 29
    if (key === Qt.Key_AsciiCircum) return 30
    if (key === Qt.Key_Underscore) return 31
    return -1
  }

  function keyPressed(event) {
    var key = event.key
    var mods = event.modifiers
    if (root.historyOpen) {
      if (key === Qt.Key_Escape) root.historyOpen = false
      else if (key === Qt.Key_PageUp || key === Qt.Key_Up) root.scrollHistory(-Math.max(1, historyFlick.height * 0.8))
      else if (key === Qt.Key_PageDown || key === Qt.Key_Down) root.scrollHistory(Math.max(1, historyFlick.height * 0.8))
      else if (key === Qt.Key_Home) root.scrollHistory(-historyFlick.contentHeight)
      else if (key === Qt.Key_End) root.scrollHistory(historyFlick.contentHeight)
      event.accepted = true
      return
    }
    if ((mods & Qt.ControlModifier) && (mods & Qt.ShiftModifier) && key === Qt.Key_Q) {
      root.close()
      event.accepted = true
      return
    }
    if (key === Qt.Key_PageUp && (mods & Qt.ShiftModifier)) {
      root.openHistory()
      event.accepted = true
      return
    }
    if (mods & Qt.ControlModifier) {
      var code = root.controlCode(key)
      if (code >= 0) root.sendText(String.fromCharCode(code))
      event.accepted = true
      return
    }
    if (key === Qt.Key_Return || key === Qt.Key_Enter) root.sendKey("Enter")
    else if (key === Qt.Key_Backspace) root.sendKey("Backspace")
    else if (key === Qt.Key_Tab) root.sendKey("Tab")
    else if (key === Qt.Key_Escape) root.sendKey("Escape")
    else if (key === Qt.Key_Up) root.sendKey("Up")
    else if (key === Qt.Key_Down) root.sendKey("Down")
    else if (key === Qt.Key_Left) root.sendKey("Left")
    else if (key === Qt.Key_Right) root.sendKey("Right")
    else if (key === Qt.Key_Home) root.sendKey("Home")
    else if (key === Qt.Key_End) root.sendKey("End")
    else if (key === Qt.Key_PageUp) root.sendKey("PageUp")
    else if (key === Qt.Key_PageDown) root.sendKey("PageDown")
    else if (key === Qt.Key_Delete) root.sendKey("Delete")
    else if (key === Qt.Key_Insert) root.sendKey("Insert")
    else if (key >= Qt.Key_F1 && key <= Qt.Key_F12) root.sendKey("F" + String(key - Qt.Key_F1 + 1))
    else {
      var text = String(event.text || "")
      if (text !== "" && !(mods & (Qt.ControlModifier | Qt.AltModifier))) return
    }
    // Unknown key events (including IME composition keys) stay with the
    // TextInput sink instead of being swallowed here.
  }

  function paintTerminal(ctx, width, height) {
    ctx.clearRect(0, 0, width, height)
    ctx.fillStyle = "#111318"
    ctx.fillRect(0, 0, width, height)
    var term = root.termScreen
    if (!term) return
    var cw = width / term.cols
    var ch = height / term.rows
    var fontSize = Math.max(8, Math.min(ch * 0.80, cw / 0.62))
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    for (var y = 0; y < term.rows; y++) {
      for (var x = 0; x < term.cols; x++) {
        var cell = term.cells[y * term.cols + x]
        if (!cell || cell.cont) continue
        var bg = cell.reverse ? cell.fg : cell.bg
        var fg = cell.reverse ? cell.bg : cell.fg
        if (bg !== "#111318") {
          ctx.fillStyle = bg
          ctx.fillRect(x * cw, y * ch, cw + 0.2, ch + 0.2)
        }
        if (cell.ch !== " " && cell.ch !== "") {
          ctx.fillStyle = fg
          ctx.font = (cell.bold ? "bold " : "") + fontSize + "px " + root.fontFamily
          ctx.fillText(cell.ch, x * cw + cw / 2, y * ch + ch / 2)
        }
        if (cell.underline) {
          ctx.strokeStyle = fg
          ctx.lineWidth = Math.max(1, ch * 0.04)
          ctx.beginPath()
          ctx.moveTo(x * cw, y * ch + ch - 1)
          ctx.lineTo((x + 1) * cw, y * ch + ch - 1)
          ctx.stroke()
        }
      }
    }
    if (term.cursor) {
      ctx.strokeStyle = root.accent
      ctx.lineWidth = Math.max(1, cw * 0.08)
      ctx.strokeRect(term.cx * cw + 1, term.cy * ch + 1, Math.max(2, cw - 2), Math.max(2, ch - 2))
    }
  }

  readonly property color background: Commons.Color.popups.background
  readonly property color foreground: Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string fontFamily: Style.font.family
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))

  Process {
    id: paneGet
    running: false
    command: ["herdr", "pane", "get", root.pane]
    stdout: StdioCollector { id: paneOut; waitForEnd: true }
    stderr: StdioCollector { id: paneErr; waitForEnd: true }
    onExited: function(code, status) { root.paneReady(paneOut.text, code) }
  }

  Process {
    id: historyProcess
    running: false
    command: []
    stdout: StdioCollector { id: historyOut; waitForEnd: true }
    stderr: StdioCollector { id: historyErr; waitForEnd: true }
    onExited: function(code, status) { root.historyReady(historyOut.text, code) }
  }

  Process {
    id: terminalControl
    running: false
    stdinEnabled: true
    command: []
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.readFrame(line) }
    }
    stderr: StdioCollector { id: controlErr; waitForEnd: false }
    onExited: function(code, status) {
      if (root.visible && root.status === "live") root.status = "terminal stream ended"
    }
  }

  Timer {
    id: resizeTimer
    interval: 180
    repeat: false
    onTriggered: root.resizeControl()
  }

  Timer {
    id: launchTimer
    interval: 120
    repeat: false
    onTriggered: {
      paneGet.running = false
      paneGet.running = true
    }
  }

  Timer {
    id: focusTimer
    interval: 160
    repeat: true
    property int tries: 0
    onTriggered: {
      tries += 1
      Quickshell.execDetached(["hyprctl", "eval", "hl.dispatch(hl.dsp.focus({ window = \"title:Reflex: " + root.termTitle + "\" }))"])
      if (typeof root.requestActivate === "function") root.requestActivate()
      terminalIme.forceActiveFocus()
      if (tries >= 6) { tries = 0; stop() }
    }
  }

  BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.background
    borderSpec: root.borderSpec
    padding: Style.spacing.panelPadding

    FocusScope {
      id: terminalFocus
      anchors.fill: parent
      anchors.margins: Style.spacing.panelPadding
      focus: true

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
            onPressed: root.startSystemMove()
          }

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "TERMINAL"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1.2
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(78)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - Style.space(160))
            text: root.pane
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(92)
            anchors.verticalCenter: parent.verticalCenter
            text: "history"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openHistory()
            }
          }

          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(30)
            anchors.verticalCenter: parent.verticalCenter
            text: "external"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openExternal()
            }
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
              onClicked: root.close()
            }
          }
        }

        Text {
          Layout.fillWidth: true
          text: root.termTitle
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          Canvas {
            id: terminalCanvas
            anchors.fill: parent
            onPaint: root.paintTerminal(getContext("2d"), width, height)
            onWidthChanged: root.requestResize()
            onHeightChanged: root.requestResize()
          }

          MouseArea {
            id: terminalMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            cursorShape: Qt.IBeamCursor
            onClicked: terminalIme.forceActiveFocus()
            onPressed: function(mouse) {
              terminalIme.forceActiveFocus()
              root.sendMouse("down", mouse.button, mouse.x, mouse.y, mouse.modifiers)
            }
            onReleased: function(mouse) {
              root.sendMouse("up", mouse.button, mouse.x, mouse.y, mouse.modifiers)
            }
            onPositionChanged: function(mouse) {
              if (pressed) root.sendMouse("drag", mouse.button, mouse.x, mouse.y, mouse.modifiers)
            }
            onWheel: function(wheel) {
              if (wheel.angleDelta.y !== 0)
                root.sendScroll(wheel.angleDelta.y > 0 ? "up" : "down", wheel.x, wheel.y, wheel.modifiers)
              wheel.accepted = true
            }
          }

          TextInput {
            id: terminalIme
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
            Keys.onPressed: function(event) { root.keyPressed(event) }
            onTextEdited: {
              var text = terminalIme.text
              if (text !== "") {
                root.sendText(text)
                terminalIme.clear()
              }
            }
            onPreeditTextChanged: root.imePreedit = terminalIme.preeditText
          }

          Text {
            anchors.centerIn: parent
            visible: root.status !== "live"
            text: root.status
            color: root.status === "terminal stream ended" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: root.imePreedit !== "" && root.termScreen
            text: root.imePreedit
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            x: root.termScreen ? root.termScreen.cx * (terminalCanvas.width / root.termScreen.cols) : 0
            y: root.termScreen ? root.termScreen.cy * (terminalCanvas.height / root.termScreen.rows) : 0
            z: 3
          }

          Rectangle {
            id: historyOverlay
            anchors.fill: parent
            visible: root.historyOpen
            color: root.background
            radius: Style.cornerRadius
            border.width: 1
            border.color: Commons.Color.popups.border
            z: 2

            Flickable {
              id: historyFlick
              anchors.fill: parent
              anchors.margins: Style.space(8)
              clip: true
              contentWidth: historyBody.width
              contentHeight: historyBody.height
              boundsBehavior: Flickable.StopAtBounds
              flickableDirection: Flickable.VerticalFlick

              Text {
                id: historyBody
                width: Math.max(historyFlick.width, implicitWidth)
                text: root.historyText
                color: root.foreground
                font.family: "monospace"
                font.pixelSize: Style.font.caption
                wrapMode: Text.NoWrap
                textFormat: Text.PlainText
              }
            }

            Text {
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              text: "history · esc closes"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          Layout.fillWidth: true
          text: "type here · shift+pgup history · external for a native client"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
