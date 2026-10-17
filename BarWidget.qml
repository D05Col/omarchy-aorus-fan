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
  readonly property var fanModes: [
    { id: "zero", label: "Zero", icon: "󰤄", desc: "Fans off (0 RPM)" },
    { id: "quiet", label: "Quiet", icon: "󰒲", desc: "Gentle low-noise curve" },
    { id: "balance", label: "Balance", icon: "󰗑", desc: "Balanced curve" },
    { id: "default", label: "Default", icon: "󰒓", desc: "Firmware default (runs 100% on this unit)" },
    { id: "performance", label: "Performance", icon: "󰓅", desc: "Aggressive curve" },
    { id: "max", label: "Max", icon: "󱐋", desc: "Fans at 100%" }
  ]
  readonly property var pumpModes: [
    { id: "balance", label: "Balance" },
    { id: "max", label: "Max" }
  ]
  readonly property bool restoreOnStart: setting("restoreOnStart", true) === true

  property bool connected: true
  property var telemetry: null
  property string fanMode: ""
  property string pumpMode: ""
  property string lastError: ""
  property int modeIndex: 0
  property bool cursorActive: false

  function modeLabel(id) {
    for (var i = 0; i < fanModes.length; i++) if (fanModes[i].id === id) return fanModes[i].label
    return ""
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(raw) {
    try {
      var s = JSON.parse(raw)
      connected = s.connected === true
      telemetry = s.telemetry || null
      fanMode = s.fan_mode || ""
      pumpMode = s.pump_mode || ""
    } catch (e) {}
  }

  function setProfile(fan, pump) {
    if (setProc.running) return
    // Show the choice immediately; the status poll after the write confirms it.
    if (fan) fanMode = fan
    if (pump) pumpMode = pump
    lastError = ""
    var cmd = ["python3", cli, "set", fan || fanMode || "balance"]
    if (pump || pumpMode) cmd.push("--pump", pump || pumpMode)
    setProc.command = cmd
    setProc.running = true
  }

  function selectByDelta(delta) {
    var n = fanModes.length
    modeIndex = (modeIndex + delta + n) % n
  }

  function activateSelected() {
    setProfile(fanModes[modeIndex].id, "")
  }

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
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
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
        // 3-column grid: left/right step by one, up/down by a row.
        if (dx !== 0) root.selectByDelta(dx)
        else if (dy !== 0) {
          var next = root.modeIndex + dy * 3
          if (next >= 0 && next < root.fanModes.length) root.modeIndex = next
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateSelected()
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

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Fan profile ----------
        Column {
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
            text: root.fanModes[root.modeIndex].desc
            visible: root.cursorActive
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Pump profile ----------
        Column {
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
                width: pumpRow.cellWidth
                text: modelData.label
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.pumpMode === modelData.id
                onClicked: root.setProfile("", modelData.id)
              }
            }
          }
        }

        Text {
          visible: root.lastError !== ""
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: root.lastError
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
