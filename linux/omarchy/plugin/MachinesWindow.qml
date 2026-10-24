import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Saved SSH machines for the Linux layer. A profile is an SSH target and the
// remote herdr socket; reflex-machines owns the systemd tunnel, while reflexd
// reads the resulting machine socket and merges those agents into /api/state.
FloatingWindow {
  id: root
  property var profiles: []
  property string status: "loading"
  signal dismissed()

  title: "Reflex: machines"
  color: "transparent"
  implicitWidth: 620
  implicitHeight: 680
  minimumSize: Qt.size(460, 480)

  readonly property color background: Commons.Color.popups.background
  readonly property color foreground: Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.6)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property string fontFamily: Style.font.family
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
  readonly property string helper: (Quickshell.env("HOME") || "") + "/.local/lib/reflex/bin/reflex-machines"

  property string addLabel: ""
  property string addTarget: ""
  property string addSocket: ""
  property string addPort: "22"
  property string addIdentity: ""

  onVisibleChanged: {
    if (visible) {
      root.refresh()
      machinesFocusTimer.tries = 0
      machinesFocusTimer.restart()
    }
  }

  function close() {
    root.visible = false
    root.dismissed()
  }

  function refresh() {
    listProcess.running = false
    listProcess.running = true
  }

  function parseProfiles(text, code) {
    if (Number(code) !== 0) { root.status = "reflex-machines failed"; return }
    var parsed = []
    try { parsed = JSON.parse(String(text || "[]")) } catch (e) { parsed = [] }
    root.profiles = Array.isArray(parsed) ? parsed : []
    root.status = root.profiles.length === 0 ? "no saved machines" : ""
  }

  function runAction(args) {
    if (actionProcess.running) return
    root.status = "working…"
    actionProcess.command = [root.helper].concat(args)
    actionProcess.running = true
  }

  function addMachine() {
    var label = String(root.addLabel || "").trim()
    var target = String(root.addTarget || "").trim()
    var socket = String(root.addSocket || "").trim()
    var port = String(root.addPort || "22").trim()
    var identity = String(root.addIdentity || "").trim()
    if (label === "" || target === "") {
      root.status = "label and SSH target are required"
      return
    }
    root.runAction(["add", label, target, socket, port, identity])
    root.addLabel = ""
    root.addTarget = ""
  }

  function removeMachine(label) {
    root.runAction(["remove", String(label)])
  }

  function setMachine(label, active) {
    root.runAction([active ? "down" : "up", String(label)])
  }

  Timer {
    id: machinesFocusTimer
    interval: 160
    repeat: true
    property int tries: 0
    onTriggered: {
      tries += 1
      Quickshell.execDetached(["hyprctl", "eval", "hl.dispatch(hl.dsp.focus({ window = \"title:^Reflex: machines$\" }))"])
      if (typeof root.requestActivate === "function") root.requestActivate()
      machinesFocus.forceActiveFocus()
      if (tries >= 6) { tries = 0; stop() }
    }
  }

  Process {
    id: listProcess
    running: false
    command: [root.helper, "list", "--json"]
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function(code, status) { root.parseProfiles(listOut.text, code) }
  }

  Process {
    id: actionProcess
    running: false
    command: [root.helper, "list"]
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(code, status) {
      if (Number(code) !== 0) root.status = String(actionErr.text || "machine action failed").trim()
      else root.status = "updated"
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
      id: machinesFocus
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

        Text {
          Layout.fillWidth: true
          text: "SSH machines"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          Layout.fillWidth: true
          text: "Forward another machine's herdr socket here. Its agents join the same list, and @machine routes to them."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        ListView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          model: root.profiles
          spacing: Style.space(6)

          delegate: Rectangle {
            required property var modelData
            width: ListView.view.width
            height: Math.max(Style.space(54), machineColumn.implicitHeight + Style.space(12))
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.foreground, root.accent)

            Column {
              id: machineColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(8)
              spacing: 2

              Row {
                spacing: Style.space(8)
                Text {
                  text: String(modelData.label || "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: modelData.active ? "connected" : "down"
                  color: modelData.active ? root.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
              Text {
                width: parent.width
                text: String(modelData.target || "") + "  " + String(modelData.remote_socket || "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
              }
              Row {
                spacing: Style.space(12)
                Text {
                  text: modelData.active ? "disconnect" : "connect"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setMachine(modelData.label, modelData.active)
                  }
                }
                Text {
                  text: "remove"
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(5)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.removeMachine(modelData.label)
                  }
                }
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          text: root.status
          color: root.status === "updated" ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 1
          color: root.dim
          opacity: 0.25
        }

        Text {
          Layout.fillWidth: true
          text: "add a machine"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        TextInput {
          id: labelInput
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(28)
          text: root.addLabel
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          selectByMouse: true
          onTextChanged: root.addLabel = text
          Keys.onReturnPressed: targetInput.forceActiveFocus()
          Text {
            anchors.fill: parent
            visible: labelInput.text === ""
            text: "label (e.g. work)"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.dim; opacity: 0.4 }
        }
        TextInput {
          id: targetInput
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(28)
          text: root.addTarget
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          selectByMouse: true
          onTextChanged: root.addTarget = text
          Keys.onReturnPressed: identityInput.forceActiveFocus()
          Text {
            anchors.fill: parent
            visible: targetInput.text === ""
            text: "ssh target (e.g. you@host)"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.dim; opacity: 0.4 }
        }
        TextInput {
          id: identityInput
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(28)
          text: root.addIdentity
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          selectByMouse: true
          onTextChanged: root.addIdentity = text
          Keys.onReturnPressed: socketInput.forceActiveFocus()
          Text {
            anchors.fill: parent
            visible: identityInput.text === ""
            text: "identity file (optional, e.g. ~/.ssh/work)"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.dim; opacity: 0.4 }
        }
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          TextInput {
            id: socketInput
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(28)
            text: root.addSocket
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            selectByMouse: true
            onTextChanged: root.addSocket = text
            Text {
              anchors.fill: parent
              visible: socketInput.text === ""
              text: "remote socket (blank = $HOME)"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.dim; opacity: 0.4 }
          }
          TextInput {
            id: portInput
            Layout.preferredWidth: Style.space(45)
            Layout.preferredHeight: Style.space(28)
            text: root.addPort
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            selectByMouse: true
            onTextChanged: root.addPort = text
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.dim; opacity: 0.4 }
          }
          Rectangle {
            Layout.preferredWidth: Style.space(60)
            Layout.preferredHeight: Style.space(28)
            radius: Style.cornerRadius
            color: Style.selectedFillFor(root.foreground, root.accent)
            Text {
              anchors.centerIn: parent
              text: "add"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.addMachine()
            }
          }
        }
      }
    }
  }
}
