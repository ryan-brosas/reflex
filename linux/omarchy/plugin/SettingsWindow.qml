import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The Linux settings surface. It is deliberately a control room, not a second
// daemon: every row calls the owner (systemd, reflexd, the helpers) and shows
// the result. macOS-only controls are named as host-owned instead of faked.
FloatingWindow {
  id: root
  property string section: "general"
  property string initialSection: "general"
  property var prefs: ({})
  property string status: ""
  property string doctorText: ""
  property string roots: ""
  property string machinesText: ""
  property string remoteState: "…"
  property string routeState: ""
  property bool signOutArmed: false
  signal dismissed()

  title: "Reflex: settings"
  color: "transparent"
  implicitWidth: 760
  implicitHeight: 650
  minimumSize: Qt.size(620, 480)

  readonly property color background: Commons.Color.popups.background
  readonly property color foreground: Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string fontFamily: Style.font.family
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string prefix: home + "/.local/lib/reflex"
  readonly property string settingsHelper: prefix + "/bin/reflex-settings"
  readonly property string doctorHelper: prefix + "/bin/reflex-doctor"
  readonly property string machinesHelper: prefix + "/bin/reflex-machines"
  readonly property string remoteHelper: prefix + "/bin/reflex-remote"
  readonly property string envFile: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/reflex/env"

  readonly property var sections: [
    { id: "general", name: "General" },
    { id: "rail", name: "Edge & Rail" },
    { id: "routing", name: "Routing" },
    { id: "terminal", name: "Terminal" },
    { id: "projects", name: "Projects" },
    { id: "phone", name: "Phone" },
    { id: "machines", name: "Machines" },
    { id: "setup", name: "Setup" },
    { id: "about", name: "About" }
  ]

  function close() {
    root.visible = false
    root.dismissed()
  }

  function refresh() {
    settingsProcess.running = false
    settingsProcess.running = true
    envProcess.running = false
    envProcess.running = true
    remoteProcess.running = false
    remoteProcess.running = true
    machinesProcess.running = false
    machinesProcess.running = true
    if (root.section === "setup" || root.section === "routing") runDoctor()
  }

  function setPref(key, value) {
    setProcess.command = [root.settingsHelper, "set", key, String(value)]
    setProcess.running = false
    setProcess.running = true
  }

  function runDoctor() {
    if (doctorProcess.running) return
    root.doctorText = "Checking…"
    doctorProcess.running = true
  }

  function testRoute() {
    root.routeState = "asking reflexd…"
    api.post("/api/route", JSON.stringify({ text: "Reflex settings check", dry: true }), "route")
  }

  function reindex() {
    root.status = "reindexing…"
    api.post("/api/reindex", JSON.stringify({ machines: true }), "reindex")
  }

  function openAsk() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{}"])
    root.close()
  }

  function openSessions() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex.sessions", "{}"])
    root.close()
  }

  function openSetup() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{\"setup\":true}"])
    root.close()
  }

  function openPair() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{\"pair\":true}"])
    root.close()
  }

  function openMachines() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{\"machines\":true}"])
    root.close()
  }

  function openTerminal() {
    Quickshell.execDetached(["xdg-terminal-exec", "herdr"])
    root.close()
  }

  function openLog() {
    Quickshell.execDetached(["xdg-terminal-exec", "journalctl", "--user", "-u", "reflexd", "-f"])
    root.close()
  }

  function restartDaemon() {
    Quickshell.execDetached(["systemctl", "--user", "restart", "reflexd.service"])
    root.status = "reflexd restarting…"
  }

  function remote(on) {
    remoteAction.command = [root.remoteHelper, on ? "on" : "off"]
    remoteAction.running = false
    remoteAction.running = true
  }

  function signOut() {
    if (!root.signOutArmed) {
      root.signOutArmed = true
      root.status = "press again to sign out every phone"
      return
    }
    root.signOutArmed = false
    rotateProcess.running = true
  }

  Timer {
    id: focusTimer
    interval: 160
    repeat: true
    property int tries: 0
    onTriggered: {
      tries += 1
      Quickshell.execDetached(["hyprctl", "eval", "hl.dispatch(hl.dsp.focus({ window = \"title:^Reflex: settings$\" }))"])
      if (typeof root.requestActivate === "function") root.requestActivate()
      settingsFocus.forceActiveFocus()
      if (tries >= 6) { tries = 0; stop() }
    }
  }

  onInitialSectionChanged: { if (root.visible) root.section = root.initialSection }
  onVisibleChanged: {
    if (visible) {
      root.section = root.initialSection
      root.status = ""
      root.signOutArmed = false
      root.refresh()
      focusTimer.tries = 0
      focusTimer.restart()
    }
  }

  Api {
    id: api
    onReply: function(tag, json) {
      if (tag === "route") {
        if (!json || json.ok !== true) root.routeState = "route failed: " + String(json && json.error ? json.error : "no answer")
        else if (json.route && json.route.decision) root.routeState = "route: " + String(json.route.decision) + (json.route.label ? " · " + String(json.route.label) : "")
        else root.routeState = "reflexd answered"
      } else if (tag === "reindex") {
        root.status = json && json.ok === true ? "index refreshed" : "reindex failed"
      }
      if (api.lastError.indexOf("401") >= 0) api.reauth()
    }
  }

  Process {
    id: settingsProcess
    running: false
    command: [root.settingsHelper, "json"]
    stdout: StdioCollector { id: settingsOut; waitForEnd: true }
    stderr: StdioCollector { id: settingsErr; waitForEnd: true }
    onExited: function(code, status) {
      if (Number(code) !== 0) { root.status = String(settingsErr.text || "settings helper failed").trim(); return }
      var parsed = ({})
      try { parsed = JSON.parse(String(settingsOut.text || "{}")) } catch (e) { parsed = ({}) }
      root.prefs = parsed
    }
  }

  Process {
    id: setProcess
    running: false
    command: [root.settingsHelper, "json"]
    stdout: StdioCollector { id: setOut; waitForEnd: true }
    stderr: StdioCollector { id: setErr; waitForEnd: true }
    onExited: function(code, status) {
      if (Number(code) !== 0) { root.status = String(setErr.text || "setting failed").trim(); return }
      root.status = "saved"
      root.refresh()
    }
  }

  Process {
    id: envProcess
    running: false
    command: ["sh", "-c", "sed -n 's/^REFLEX_ROOTS=//p' \"$1\" | tail -1", "sh", root.envFile]
    stdout: StdioCollector { id: envOut; waitForEnd: true }
    onExited: function(code, status) { root.roots = String(envOut.text || "").trim() || "not set" }
  }

  Process {
    id: doctorProcess
    running: false
    command: [root.doctorHelper]
    stdout: StdioCollector { id: doctorOut; waitForEnd: true }
    stderr: StdioCollector { id: doctorErr; waitForEnd: true }
    onExited: function(code, status) {
      root.doctorText = String(doctorOut.text || doctorErr.text || "").trim()
      root.status = Number(code) === 0 ? "checks passed" : "checks reported a failure"
    }
  }

  Process {
    id: machinesProcess
    running: false
    command: [root.machinesHelper, "list"]
    stdout: StdioCollector { id: machinesOut; waitForEnd: true }
    stderr: StdioCollector { id: machinesErr; waitForEnd: true }
    onExited: function(code, status) {
      var text = String(machinesOut.text || "").trim()
      root.machinesText = text === "" ? "no saved machines" : text
    }
  }

  Process {
    id: remoteProcess
    running: false
    command: [root.remoteHelper, "status"]
    stdout: StdioCollector { id: remoteOut; waitForEnd: true }
    onExited: function(code, status) { root.remoteState = String(remoteOut.text || "unknown").trim() }
  }

  Process {
    id: remoteAction
    running: false
    command: [root.remoteHelper, "status"]
    stdout: StdioCollector { id: remoteActionOut; waitForEnd: true }
    stderr: StdioCollector { id: remoteActionErr; waitForEnd: true }
    onExited: function(code, status) {
      root.status = Number(code) === 0 ? "phone endpoint updated" : String(remoteActionErr.text || "phone helper failed").trim()
      root.refresh()
    }
  }

  Process {
    id: rotateProcess
    running: false
    command: [root.remoteHelper, "rotate"]
    stdout: StdioCollector { id: rotateOut; waitForEnd: true }
    stderr: StdioCollector { id: rotateErr; waitForEnd: true }
    onExited: function(code, status) {
      root.status = Number(code) === 0 ? "phones signed out" : String(rotateErr.text || "sign out failed").trim()
      if (Number(code) === 0) api.reauth()
      root.refresh()
    }
  }

  BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.background
    borderSpec: root.borderSpec
    padding: Style.spacing.panelPadding

    FocusScope {
      id: settingsFocus
      anchors.fill: parent
      anchors.margins: Style.spacing.panelPadding
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
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
            onPressed: root.startSystemMove()
          }
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "REFLEX / SETTINGS"
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
              onClicked: root.close()
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(12)

          Column {
            Layout.preferredWidth: Style.space(150)
            Layout.fillHeight: true
            spacing: Style.space(2)

            Repeater {
              model: root.sections
              Rectangle {
                width: parent.width
                height: Style.space(30)
                radius: Style.cornerRadius
                color: root.section === modelData.id ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.name
                  color: root.section === modelData.id ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: root.section === modelData.id
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.section = modelData.id
                    if (modelData.id === "setup" || modelData.id === "routing") root.runDoctor()
                  }
                }
              }
            }

            Item { width: 1; height: Style.space(8) }

            Text {
              width: parent.width
              text: "These are host-owned controls. No secret is shown here."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              opacity: 0.7
            }
          }

          Rectangle {
            Layout.preferredWidth: Math.max(1, Style.space(1))
            Layout.fillHeight: true
            color: root.borderColor
            opacity: 0.4
          }

          Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: width
            contentHeight: detail.height + Style.space(16)
            flickableDirection: Flickable.VerticalFlick

            Column {
              id: detail
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: root.section === "general" ? "General"
                    : root.section === "rail" ? "Edge & Rail"
                    : root.section === "routing" ? "Routing"
                    : root.section === "terminal" ? "Terminal"
                    : root.section === "projects" ? "Projects"
                    : root.section === "phone" ? "Phone"
                    : root.section === "machines" ? "Machines"
                    : root.section === "setup" ? "Setup"
                    : "About"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                width: parent.width
                visible: root.section === "general"
                text: "Reflex is a daemon, a bar widget and a normal app window. These controls call the owner of each piece; nothing is duplicated here."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Row {
                visible: root.section === "general"
                spacing: Style.space(8)
                Repeater {
                  model: [
                    { label: "open ask", action: "ask" },
                    { label: "sessions", action: "sessions" },
                    { label: "guided setup", action: "setup" },
                    { label: "open log", action: "log" }
                  ]
                  Rectangle {
                    width: Style.space(104)
                    height: Style.space(32)
                    radius: Style.cornerRadius
                    color: Style.selectedFillFor(root.foreground, root.accent)
                    Text {
                      anchors.centerIn: parent
                      text: modelData.label
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (modelData.action === "ask") root.openAsk()
                        else if (modelData.action === "sessions") root.openSessions()
                        else if (modelData.action === "setup") root.openSetup()
                        else root.openLog()
                      }
                    }
                  }
                }
              }

              Row {
                visible: root.section === "general"
                spacing: Style.space(8)
                Rectangle {
                  width: Style.space(104)
                  height: Style.space(32)
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: 1
                  border.color: root.dim
                  Text {
                    anchors.centerIn: parent
                    text: "restart reflexd"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.restartDaemon()
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.section === "rail"
                text: "The 6 px reserved strip is left of the bar when the bar is vertical. The hover surface widens without moving windows."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              Column {
                width: parent.width
                visible: root.section === "rail"
                spacing: Style.space(4)

                Repeater {
                  model: [
                    { key: "railReserve", label: "reserve the 6 px rail strip" },
                    { key: "surfaceQuestions", label: "surface questions as a toast" },
                    { key: "keepAwake", label: "keep the session awake while agents work" }
                  ]
                  Rectangle {
                    width: parent.width
                    height: Style.space(36)
                    radius: Style.cornerRadius
                    color: Style.selectedFillFor(root.foreground, root.dim)
                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.label
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    Rectangle {
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(38)
                      height: Style.space(20)
                      radius: height / 2
                      color: root.prefs[modelData.key] === false ? root.dim : root.accent
                      Rectangle {
                        width: Style.space(14)
                        height: width
                        radius: width / 2
                        y: Style.space(3)
                        x: root.prefs[modelData.key] === false ? Style.space(3) : parent.width - width - Style.space(3)
                        color: root.background
                      }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setPref(modelData.key, root.prefs[modelData.key] === false)
                      }
                    }
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.section === "routing"
                text: "Jev decides where each request goes. The credential stays in ~/.config/jev-fabric/pi-env.sh; this pane only checks that reflexd can route."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Row {
                visible: root.section === "routing"
                spacing: Style.space(8)
                Rectangle {
                  width: Style.space(104)
                  height: Style.space(32)
                  radius: Style.cornerRadius
                  color: Style.selectedFillFor(root.foreground, root.accent)
                  Text {
                    anchors.centerIn: parent
                    text: "test route"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.testRoute() }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.routeState
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                width: parent.width
                visible: root.section === "terminal"
                text: "herdr owns the PTY. The embedded view observes its ANSI frames and sends keys; the native terminal stays the fidelity path for full-screen TUIs, mouse reporting and IME."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                visible: root.section === "terminal"
                text: "open: xdg-terminal-exec herdr\nattach: xdg-terminal-exec herdr agent attach <pane>"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }
              Rectangle {
                visible: root.section === "terminal"
                width: Style.space(104)
                height: Style.space(32)
                radius: Style.cornerRadius
                color: Style.selectedFillFor(root.foreground, root.accent)
                Text {
                  anchors.centerIn: parent
                  text: "open herdr"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openTerminal() }
              }

              Text {
                width: parent.width
                visible: root.section === "projects"
                text: "Roots come from REFLEX_ROOTS in " + root.envFile + ". Reindex asks reflexd to rebuild the folder table; it does not write your projects."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                visible: root.section === "projects"
                text: root.roots
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }
              Rectangle {
                visible: root.section === "projects"
                width: Style.space(104)
                height: Style.space(32)
                radius: Style.cornerRadius
                color: Style.selectedFillFor(root.foreground, root.accent)
                Text {
                  anchors.centerIn: parent
                  text: "reindex folders"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.reindex() }
              }

              Text {
                width: parent.width
                visible: root.section === "phone"
                text: "Pairing opens the phone-facing port for a one-time code. Signing out rotates the bearer token and restarts reflexd; every paired phone needs a new code."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                visible: root.section === "phone"
                text: "endpoint: " + root.remoteState
                color: root.remoteState === "local" || root.remoteState === "remote" ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Row {
                visible: root.section === "phone"
                spacing: Style.space(8)
                Repeater {
                  model: [
                    { label: "pair phone", action: "pair" },
                    { label: "open port", action: "on" },
                    { label: "close port", action: "off" },
                    { label: root.signOutArmed ? "confirm sign out" : "sign out phones", action: "signout" }
                  ]
                  Rectangle {
                    width: Style.space(108)
                    height: Style.space(32)
                    radius: Style.cornerRadius
                    color: Style.selectedFillFor(root.foreground, modelData.action === "signout" ? root.urgent : root.accent)
                    Text {
                      anchors.centerIn: parent
                      text: modelData.label
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        if (modelData.action === "pair") root.openPair()
                        else if (modelData.action === "on") root.remote(true)
                        else if (modelData.action === "off") root.remote(false)
                        else root.signOut()
                      }
                    }
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.section === "machines"
                text: "A profile forwards another machine's herdr socket here. Its agents join the same list; remote folders are indexed after the tunnel is up."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                visible: root.section === "machines"
                text: root.machinesText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }
              Rectangle {
                visible: root.section === "machines"
                width: Style.space(112)
                height: Style.space(32)
                radius: Style.cornerRadius
                color: Style.selectedFillFor(root.foreground, root.accent)
                Text {
                  anchors.centerIn: parent
                  text: "manage machines"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openMachines() }
              }

              Text {
                width: parent.width
                visible: root.section === "setup"
                text: "The readiness report is the same one the guided setup shows. It never prints a secret."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Rectangle {
                visible: root.section === "setup"
                width: Style.space(100)
                height: Style.space(32)
                radius: Style.cornerRadius
                color: Style.selectedFillFor(root.foreground, root.accent)
                Text {
                  anchors.centerIn: parent
                  text: "run checks"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.runDoctor() }
              }
              Text {
                width: parent.width
                visible: root.section === "setup"
                text: root.doctorText === "" ? "Not run yet." : root.doctorText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
              }

              Text {
                width: parent.width
                visible: root.section === "about"
                text: "Reflex on Omarchy\nreflexd: " + root.prefix + "/reflexd\nsettings: " + root.settingsHelper + "\nphone: " + root.remoteHelper
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                lineHeight: 1.4
                wrapMode: Text.WrapAnywhere
              }
              Text {
                width: parent.width
                visible: root.section === "about"
                text: "The daemon, routing and question parsing are shared with the macOS app. Terminal appearance and the wallpaper belong to Omarchy."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                visible: root.status !== ""
                text: root.status
                color: root.status.indexOf("failed") >= 0 || root.status.indexOf("error") >= 0 ? root.urgent : root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Item { width: 1; height: Style.space(8) }
            }
          }
        }
      }
    }
  }
}
