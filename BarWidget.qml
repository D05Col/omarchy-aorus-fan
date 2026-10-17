import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "dylan.aorus-fan"
  ipcTarget: "dylan.aorus-fan"

  // All device logic lives in the bundled CLI; this file is only the UI.
  readonly property string cli: Qt.resolvedUrl("bin/aorus-fan").toString().replace("file://", "")
  // Run as root through pkexec, so the polkit dialog shows exactly what is written.
  // Keep in sync with the udev rule in the README.
  readonly property string udevRule: 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1044", ATTRS{idProduct}=="7a4d", TAG+="uaccess"'
  readonly property string udevInstallScript: 'printf "%s\\n" "$1" > /etc/udev/rules.d/70-waterforce.rules'
    + ' && udevadm control --reload-rules && udevadm trigger --subsystem-match=hidraw --action=change'
  readonly property var fanModes: [
    { id: "zero", label: "Zero", icon: "󰤄", desc: "Fans off (0 RPM)" },
    { id: "quiet", label: "Quiet", icon: "󰒲", desc: "Gentle low-noise curve" },
    { id: "balance", label: "Balance", icon: "󰗑", desc: "Balanced curve" },
    { id: "default", label: "Default", icon: "󰒓", desc: "Firmware default curve (may run at full speed)" },
    { id: "performance", label: "Performance", icon: "󰓅", desc: "Aggressive curve" },
    { id: "max", label: "Max", icon: "󱐋", desc: "Fans at 100%" }
  ]
  readonly property var pumpModes: [
    { id: "balance", label: "Balance" },
    { id: "max", label: "Max" }
  ]
  readonly property bool restoreOnStart: setting("restoreOnStart", true) === true

  property bool connected: false
  property bool writable: true
  property var telemetry: null
  property string fanMode: ""
  property string pumpMode: ""
  property string lastError: ""
  property string statusError: ""
  property bool refreshQueued: false
  property int modeIndex: 0
  property bool cursorActive: false

  function modeLabel(id) {
    for (var i = 0; i < fanModes.length; i++) if (fanModes[i].id === id) return fanModes[i].label
    return ""
  }

  // A request made while a poll is in flight reruns it, so a stale result cannot stick.
  function refresh() {
    if (statusProc.running) refreshQueued = true
    else statusProc.running = true
  }

  function applyStatus(raw, err, code) {
    var s = null
    if (code !== 0) statusError = err.trim() || "aorus-fan exited with code " + code
    else {
      try {
        s = JSON.parse(raw)
        statusError = ""
      } catch (e) {
        statusError = "Unexpected output from aorus-fan"
      }
    }
    connected = s !== null && s.connected === true
    writable = s === null || s.writable !== false
    telemetry = s && s.telemetry ? s.telemetry : null
    fanMode = s && s.fan_mode ? s.fan_mode : ""
    pumpMode = s && s.pump_mode ? s.pump_mode : ""
  }

  // Pass only what changed; the CLI fills in the other channel from the saved profile.
  function setProfile(fan, pump) {
    if (setProc.running) return
    // Show the choice immediately; the status poll after the write confirms it.
    if (fan) fanMode = fan
    if (pump) pumpMode = pump
    lastError = ""
    var cmd = ["python3", cli, "set"]
    if (fan) cmd.push(fan)
    if (pump) cmd.push("--pump", pump)
    setProc.command = cmd
    setProc.running = true
  }

  function authorize() {
    if (authProc.running) return
    lastError = ""
    authProc.running = true
  }

  // Keyboard cursor: 0-5 are the fan grid (3 columns), 6-7 the pump row below it.
  function selectByDelta(delta) {
    var n = fanModes.length + pumpModes.length
    modeIndex = (modeIndex + delta + n) % n
  }

  function selectByRow(dy) {
    var fanCount = fanModes.length
    if (modeIndex < fanCount) {
      if (dy < 0 && modeIndex >= 3) modeIndex -= 3
      else if (dy > 0) modeIndex = modeIndex < 3 ? modeIndex + 3 : fanCount + (modeIndex === fanCount - 1 ? 1 : 0)
    } else if (dy < 0) {
      modeIndex = modeIndex === fanCount ? 3 : fanCount - 1
    }
  }

  function activateSelected() {
    if (modeIndex < fanModes.length) setProfile(fanModes[modeIndex].id, "")
    else setProfile("", pumpModes[modeIndex - fanModes.length].id)
  }

  readonly property string shownError: lastError !== "" ? lastError : statusError
  readonly property var cpuTemp: telemetry && telemetry.cpu_temp !== null ? telemetry.cpu_temp : null

  readonly property string tooltip: {
    if (!connected) return "AORUS cooler not found"
    var parts = ["AORUS Fan · " + (fanMode ? modeLabel(fanMode) : "unknown profile")]
    if (telemetry) {
      var t = telemetry.fan_rpm + " RPM · coolant " + telemetry.temp.toFixed(1) + "°C"
      if (cpuTemp !== null) t += " · CPU " + cpuTemp.toFixed(0) + "°C"
      parts.push(t)
    }
    return parts.join("\n")
  }

  onOpenedChanged: {
    if (opened) {
      var idx = -1
      for (var i = 0; i < fanModes.length; i++) if (fanModes[i].id === fanMode) idx = i
      modeIndex = idx >= 0 ? idx : 0
      cursorActive = false
      refresh()
    }
  }

  Component.onCompleted: {
    refresh()
    if (restoreOnStart) restoreProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: ["python3", root.cli, "status", "--json"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(code) {
      root.applyStatus(statusOut.text, statusErr.text, code)
      if (root.refreshQueued) {
        root.refreshQueued = false
        running = true
      }
    }
  }

  Process {
    id: setProc
    stderr: StdioCollector { id: setErr; waitForEnd: true }
    onExited: function(code) {
      root.lastError = code === 0 ? "" : setErr.text.trim()
      root.refresh()
      // Fan speed takes a moment to follow the new profile.
      settleTimer.restart()
    }
  }

  Process {
    id: authProc
    command: ["pkexec", "/bin/sh", "-c", root.udevInstallScript, "sh", root.udevRule]
    stderr: StdioCollector { id: authErr; waitForEnd: true }
    onExited: function(code) {
      // pkexec exits 126/127 when the password prompt is dismissed or refused.
      var err = authErr.text.trim()
      if (code !== 0) root.lastError = err || (code === 126 || code === 127 ? "Authorization cancelled" : "Authorization failed (exit " + code + ")")
      root.refresh()
      settleTimer.restart()
    }
  }

  Process {
    id: restoreProc
    command: ["python3", root.cli, "restore"]
    onExited: root.refresh()
  }

  Timer { id: settleTimer; interval: 2500; onTriggered: root.refresh() }
  Timer { interval: 2000; running: root.opened; repeat: true; onTriggered: root.refresh() }
  Timer { interval: 30000; running: !root.opened; repeat: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰈐"
    dimmed: !root.connected
    tooltipText: root.tooltip
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        // Left/right step by one; up/down move between the fan rows and the pump row.
        if (dx !== 0) root.selectByDelta(dx)
        else if (dy !== 0) root.selectByRow(dy)
      }
      onActivateRequested: {
        if (!root.connected) return
        if (!root.writable) root.authorize()
        else if (root.cursorActive) root.activateSelected()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroRpm.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰈐"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroRpm.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "AORUS Waterforce"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: (!root.connected ? "NOT DETECTED"
                : root.fanMode ? root.modeLabel(root.fanMode).toUpperCase() : "PROFILE UNKNOWN")
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroRpm
            textFormat: Text.PlainText
            text: root.telemetry ? root.telemetry.fan_rpm : "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Stats ----------
        Row {
          visible: root.telemetry !== null
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Fan"; value: root.telemetry ? root.telemetry.fan_rpm + " RPM · " + root.telemetry.fan_duty + "%" : "" }
            InfoPair { label: "Pump"; value: root.telemetry ? root.telemetry.pump_rpm + " RPM · " + root.telemetry.pump_duty + "%" : "" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Coolant"; value: root.telemetry ? root.telemetry.temp.toFixed(1) + " °C" : "" }
            InfoPair { label: "CPU"; value: root.cpuTemp !== null ? root.cpuTemp.toFixed(1) + " °C" : "—" }
          }
        }

        PanelSeparator { visible: root.connected; foreground: root.bar.foreground }

        // ---------- Access ----------
        Column {
          visible: root.connected && !root.writable
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: parent.width
            iconText: "󰒃"
            iconSize: Style.font.title
            text: authProc.running ? "Authorizing…" : "Authorize fan control"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            hasCursor: true
            onClicked: root.authorize()
          }

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: "Allow this user to change fan and pump profiles. Installs a udev rule for the cooler and asks for your password."
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Fan profile ----------
        Column {
          visible: root.connected && root.writable
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "FAN PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Grid {
            id: modeGrid
            width: parent.width
            columns: 3
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

            Repeater {
              model: root.fanModes
              Button {
                required property var modelData
                required property int index
                width: modeGrid.cellWidth
                iconText: modelData.icon
                iconSize: Style.font.title
                text: modelData.label
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.fanMode === modelData.id
                hasCursor: root.cursorActive && root.modeIndex === index
                onClicked: root.setProfile(modelData.id, "")
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.modeIndex = index
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.modeIndex < root.fanModes.length ? root.fanModes[root.modeIndex].desc : ""
            visible: root.cursorActive && text !== ""
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator { visible: root.connected && root.writable; foreground: root.bar.foreground }

        // ---------- Pump profile ----------
        Column {
          visible: root.connected && root.writable
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "PUMP PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: pumpRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Repeater {
              model: root.pumpModes
              Button {
                required property var modelData
                required property int index
                width: pumpRow.cellWidth
                text: modelData.label
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.pumpMode === modelData.id
                hasCursor: root.cursorActive && root.modeIndex === root.fanModes.length + index
                onClicked: root.setProfile("", modelData.id)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.modeIndex = root.fanModes.length + index
                  }
                }
              }
            }
          }
        }

        Text {
          visible: root.shownError !== ""
          width: parent.width
          wrapMode: Text.WrapAtWordBoundaryOrAnywhere
          textFormat: Text.PlainText
          text: root.shownError
          color: Color.accent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  component InfoPair: Item {
    property string label: ""
    property string value: ""

    width: parent.width
    implicitHeight: valueText.implicitHeight

    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: root.bar.foreground
      opacity: 0.6
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      id: valueText
      anchors.right: parent.right
      textFormat: Text.PlainText
      text: parent.value
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
