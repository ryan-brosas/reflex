import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A guided first-run path, not a second doctor. Each step points at the real
// surface it introduces; the doctor report is shown in place so a failure is
// actionable before the window closes.
FloatingWindow {
  id: root
  property int step: 0
  property string doctorText: ""
  property string status: ""
  property bool busy: false
  signal dismissed()

  title: "Reflex: setup"
  color: "transparent"
  implicitWidth: 600
  implicitHeight: 640
  minimumSize: Qt.size(480, 480)

  readonly property color background: Commons.Color.popups.background
  readonly property color foreground: Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string fontFamily: Style.font.family
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
  readonly property string marker: (Quickshell.env("HOME") || "") + "/.config/reflex/onboarded"
  readonly property var titles: [
    "Meet Reflex", "Check this machine", "Your agents have a terminal",
    "Projects become routes", "Other machines, same Reflex",
    "Bring your phone", "Ready"
  ]
  readonly property var bodies: [
    "Reflex watches herdr, brings agent questions to the bar, and routes one sentence to the right session. This setup takes about a minute.",
    "",
    "herdr still owns the terminal. Open the ask bar, choose a session, and press shift+return for an embedded view; the native terminal stays available for full-screen TUIs.",
    "Reflex routes across REFLEX_ROOTS. The Projects settings show the configured roots and can ask reflexd to rebuild the folder table without writing to your projects.",
    "An SSH machine is a saved target plus a forwarded herdr socket. Add one to see its agents and index its project folders; there is no saved machine on this box yet.",
    "Pairing opens a one-time QR and a phone-facing port. Closing the card before it is scanned restores loopback; you can skip this and pair later from /pair.",
    "Reflex is set up. Open the ask bar with SUPER ALT A, or open this setup again from the Reflex menu."
  ]

  onVisibleChanged: {
    if (visible) {
      root.step = 0
      root.doctorText = ""
      root.status = ""
      root.busy = false
      setupFocus.forceActiveFocus()
      setupFocusTimer.tries = 0
      setupFocusTimer.restart()
    }
  }

  function close() {
    root.visible = false
    root.dismissed()
  }

  function finish() {
    markProcess.running = true
    root.close()
  }

  function runChecks() {
    if (root.busy) return
    root.busy = true
    root.status = "running checks…"
    doctorProcess.running = false
    doctorProcess.running = true
  }

  function doctorReady(text, code) {
    root.busy = false
    root.doctorText = String(text || "")
    root.status = Number(code) === 0 ? "checks complete" : "checks reported a failure"
  }

  function next() {
    if (root.step < 6) root.step++
  }

  function back() {
    if (root.step > 0) root.step--
  }

  function openAsk() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{}"])
    root.finish()
  }

  function openPair() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{\"pair\":true}"])
  }

  function openProjects() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{\"settings\":\"projects\"}"])
  }

  function openMachines() {
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "reflex", "{\"machines\":true}"])
  }

  Timer {
    id: setupFocusTimer
    interval: 160
    repeat: true
    property int tries: 0
    onTriggered: {
      tries += 1
      Quickshell.execDetached(["hyprctl", "eval", "hl.dispatch(hl.dsp.focus({ window = \"title:^Reflex: setup$\" }))"])
      if (typeof root.requestActivate === "function") root.requestActivate()
      setupFocus.forceActiveFocus()
      if (tries >= 6) { tries = 0; stop() }
    }
  }

  Process {
    id: doctorProcess
    running: false
    command: [(Quickshell.env("HOME") || "") + "/.local/lib/reflex/bin/reflex-doctor"]
    stdout: StdioCollector { id: doctorOut; waitForEnd: true }
    stderr: StdioCollector { id: doctorErr; waitForEnd: true }
    onExited: function(code, status) { root.doctorReady(doctorOut.text, code) }
  }

  Process {
    id: markProcess
    running: false
    command: ["touch", root.marker]
  }

  BorderSurface {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.background
    borderSpec: root.borderSpec
    padding: Style.spacing.panelPadding

    FocusScope {
      id: setupFocus
      anchors.fill: parent
      anchors.margins: Style.spacing.panelPadding
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (root.step === 6) root.openAsk()
          else if (root.step === 1 && root.doctorText === "") root.runChecks()
          else root.next()
          event.accepted = true; return
        }
        if (event.key === Qt.Key_Backspace) { root.back(); event.accepted = true; return }
        if (event.key === Qt.Key_R) { root.runChecks(); event.accepted = true; return }
        if (event.key === Qt.Key_P) { root.openPair(); event.accepted = true; return }
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

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
              onClicked: root.close()
            }
          }
        }

        Row {
          spacing: Style.space(5)
          Repeater {
            model: 7
            Rectangle {
              width: Style.space(18)
              height: Style.space(2)
              radius: 1
              color: index <= root.step ? root.accent : root.dim
              opacity: index <= root.step ? 1 : 0.35
            }
          }
        }

        Text {
          Layout.fillWidth: true
          text: root.titles[root.step]
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          Layout.fillWidth: true
          visible: root.step !== 1
          text: root.bodies[root.step]
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Text {
          Layout.fillWidth: true
          visible: root.step === 1
          text: "Run the readiness checks. They report the daemon, herdr, plugins, earlier sessions and pairing availability without printing a secret."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Flickable {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.step === 1
          clip: true
          contentWidth: width
          contentHeight: doctorBody.height + Style.space(8)
          flickableDirection: Flickable.VerticalFlick
          Text {
            id: doctorBody
            width: parent.width
            text: root.doctorText === "" ? "Not run yet." : root.doctorText
            color: root.doctorText === "" ? root.dim : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.status !== ""
          text: root.status
          color: root.busy ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Item { Layout.fillHeight: true }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Rectangle {
            visible: root.step > 0
            Layout.preferredWidth: Style.space(68)
            Layout.preferredHeight: Style.space(34)
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: root.dim
            Text {
              anchors.centerIn: parent
              text: "back"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.back() }
          }

          Item { Layout.fillWidth: true }

          Rectangle {
            visible: root.step === 1
            Layout.preferredWidth: Style.space(104)
            Layout.preferredHeight: Style.space(34)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.foreground, root.accent)
            Text {
              anchors.centerIn: parent
              text: root.busy ? "checking…" : "run checks"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; enabled: !root.busy; onClicked: root.runChecks() }
          }

          Rectangle {
            visible: root.step === 3 || root.step === 4 || root.step === 5
            Layout.preferredWidth: Style.space(root.step === 4 ? 84 : 76)
            Layout.preferredHeight: Style.space(34)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.foreground, root.accent)
            Text {
              anchors.centerIn: parent
              text: root.step === 3 ? "projects" : root.step === 4 ? "machines" : "pair"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.step === 3 ? root.openProjects() : root.step === 4 ? root.openMachines() : root.openPair()
            }
          }

          Rectangle {
            Layout.preferredWidth: root.step === 6 ? Style.space(90) : Style.space(68)
            Layout.preferredHeight: Style.space(34)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.foreground, root.accent)
            Text {
              anchors.centerIn: parent
              text: root.step === 6 ? "open ask" : (root.step === 5 ? "skip" : "next")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.step === 6 ? root.openAsk() : root.next()
            }
          }
        }
      }
    }
  }
}
