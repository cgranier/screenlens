import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui as Ui
import ".." as SLRoot

// Non-blocking floating pill shown while Recapture mode is armed so the user
// can freely scroll, switch tabs, or focus another window before snapping a
// fresh frame into their active ScreenLens conversation.
PanelWindow {
  id: pillWindow

  property bool armed: false
  property color bgColor: "#181a22"
  property color fgColor: "#e6e9f2"
  property color accentColor: "#7aa2f7"
  property color hairlineColor: "#24e6e9f2"
  property var cardBorderSpec: Border.flat("#353b4d", 2)
  property int cornerRadius: Style.cornerRadius
  property string uiFont: Style.font.menuFamily
  property string hintText: "Scroll or switch windows, then click Snap"
  property string snapLabel: "Snap Screen"
  property string resumeLabel: "Resume"

  signal snapRequested()
  signal resumeRequested()

  property var targetScreen: null

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    for (var i = 0; i < Quickshell.screens.length; i++) {
      if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
    }
    return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  }

  onArmedChanged: {
    targetScreen = armed ? focusedScreen() : null
    if (armed) Hyprland.refreshMonitors()
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      if (pillWindow.armed && Quickshell.screens.indexOf(pillWindow.targetScreen) < 0) {
        pillWindow.targetScreen = null
        Qt.callLater(function() {
          if (pillWindow.armed && !pillWindow.targetScreen) {
            pillWindow.targetScreen = pillWindow.focusedScreen()
          }
        })
      }
    }
  }

  visible: armed && !!targetScreen
  screen: targetScreen
  anchors { top: true }
  margins { top: Math.max(Style.gapsOut, Style.space(16)) }
  implicitWidth: pillCard.implicitWidth + Style.space(8)
  implicitHeight: pillCard.implicitHeight + Style.space(8)
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  WlrLayershell.namespace: "screenlens"

  Ui.BorderSurface {
    id: pillCard
    anchors.centerIn: parent
    color: pillWindow.bgColor
    borderSpec: pillWindow.cardBorderSpec
    radius: pillWindow.cornerRadius
    padding: Style.spacing.xs
    implicitWidth: pillRow.implicitWidth + padding * 2 + Border.left(borderSpec) + Border.right(borderSpec) + Style.space(8)
    implicitHeight: pillRow.implicitHeight + padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.spacing.sm

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(8)
        height: Style.space(8)
        radius: width / 2
        color: pillWindow.accentColor
      }

      SLRoot.PlainText {
        anchors.verticalCenter: parent.verticalCenter
        text: pillWindow.hintText
        color: pillWindow.fgColor
        font.family: pillWindow.uiFont
        font.pixelSize: Style.font.bodySmall
      }

      Rectangle {
        width: 1
        height: Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
        color: pillWindow.hairlineColor
      }

      Ui.Button {
        foreground: pillWindow.fgColor
        text: pillWindow.snapLabel
        iconText: "󰑐"
        fontSize: Style.font.bodySmall
        selected: true
        bordered: true
        onClicked: pillWindow.snapRequested()
      }

      Ui.Button {
        foreground: pillWindow.fgColor
        text: pillWindow.resumeLabel
        iconText: "󰜺"
        fontSize: Style.font.bodySmall
        onClicked: pillWindow.resumeRequested()
      }
    }
  }
}
