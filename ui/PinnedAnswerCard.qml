import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui as Ui
import ".." as SLRoot
import "../ScreenLensLogic.js" as Logic

// Non-blocking, draggable, always-on-top floating mini answer card.
// Uses a masked Wayland layer-shell surface with WlrKeyboardFocus.None so
// underlying terminals, editors, and browsers remain 100% interactive outside
// the card while keeping the pinned answer and code copy buttons visible.
PanelWindow {
  id: pinWin

  property bool shown: false
  property var pinnedData: null
  property color bgColor: "#181a22"
  property color fgColor: "#e6e9f2"
  property color accentColor: "#7aa2f7"
  property color borderColor: "#353b4d"
  property color hairlineColor: "#22ffffff"
  property color hoverFill: "#1affffff"
  property color mutedInk: "#88e6e9f2"
  property int cornerRadius: Style.cornerRadius
  property string uiFont: Style.font.family
  property string themeMode: "system"
  property var strings: null

  property bool collapsed: false
  property bool dragging: false
  property bool hasCustomPos: false
  property real cardX: 0
  property real cardY: 0
  property real dragStartMouseX: 0
  property real dragStartMouseY: 0
  property real dragStartCardX: 0
  property real dragStartCardY: 0
  property bool copiedFlash: false

  signal copyRequested(string text)
  signal reexpandRequested(var pinned)
  signal closeRequested()

  property var targetScreen: null
  readonly property int edgeMargin: Math.max(Style.gapsOut, Style.space(18))
  readonly property int cardWidth: Math.min(Style.space(390), Math.max(Style.space(280), width - edgeMargin * 2))
  readonly property int maxBodyHeight: Math.min(Math.max(Style.space(180), height * 0.42), Style.space(340))
  readonly property var cardBorderSpec: themeMode === "system"
    ? Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
    : Border.flat(borderColor, Math.max(1, Style.space(2)))

  readonly property string answerText: pinnedData && pinnedData.answer ? String(pinnedData.answer) : ""
  readonly property string titleText: pinnedData && pinnedData.title ? String(pinnedData.title) : "ScreenLens"
  readonly property string providerText: pinnedData && pinnedData.providerLabel ? String(pinnedData.providerLabel) : ""
  readonly property bool usedWebSearch: !!(pinnedData && pinnedData.webSearch === true)
  readonly property var answerBlocks: answerText.length > 0 ? Logic.parseAnswerBlocks(answerText) : []

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    for (var i = 0; i < Quickshell.screens.length; i++) {
      if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
    }
    return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  }

  function resetToDefaultCorner() {
    hasCustomPos = false
    collapsed = false
    if (width > 0 && height > 0) {
      var pos = Logic.clampFloatingPosition(
        width - cardWidth - edgeMargin,
        height - cardSurface.implicitHeight - edgeMargin,
        cardWidth,
        cardSurface.implicitHeight,
        width,
        height,
        edgeMargin
      )
      cardX = pos.x
      cardY = pos.y
    }
  }

  function clampCard() {
    if (width <= 0 || height <= 0) return
    var desiredX = hasCustomPos ? cardX : (width - cardWidth - edgeMargin)
    var desiredY = hasCustomPos ? cardY : (height - cardSurface.implicitHeight - edgeMargin)
    var pos = Logic.clampFloatingPosition(
      desiredX,
      desiredY,
      cardWidth,
      cardSurface.implicitHeight,
      width,
      height,
      edgeMargin
    )
    cardX = pos.x
    cardY = pos.y
  }

  function flashCopied() {
    copiedFlash = true
    copiedTimer.restart()
  }

  onShownChanged: {
    if (shown) {
      targetScreen = focusedScreen()
      collapsed = false
      Qt.callLater(clampCard)
    } else {
      dragging = false
      targetScreen = null
    }
  }

  onPinnedDataChanged: {
    if (!pinnedData) {
      hasCustomPos = false
      collapsed = false
    } else if (shown) {
      collapsed = false
      Qt.callLater(clampCard)
    }
  }

  onWidthChanged: if (shown) clampCard()
  onHeightChanged: if (shown) clampCard()

  Connections {
    target: Quickshell
    function onScreensChanged() {
      if (pinWin.shown && Quickshell.screens.indexOf(pinWin.targetScreen) < 0) {
        pinWin.targetScreen = pinWin.focusedScreen()
        Qt.callLater(pinWin.clampCard)
      }
    }
  }

  visible: shown && !!targetScreen && !!pinnedData
  screen: targetScreen
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "screenlens-pin"
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // Restrict Wayland pointer input strictly to the mini card so everything
  // else on screen passes clicks straight through to underlying apps.
  mask: Region {
    item: pinWin.shown ? (pinWin.dragging ? dragCatcher : cardSurface) : null
  }

  Timer {
    id: copiedTimer
    interval: 1500
    repeat: false
    onTriggered: pinWin.copiedFlash = false
  }

  Item {
    id: dragCatcher
    anchors.fill: parent
  }

  Ui.BorderSurface {
    id: cardSurface
    x: pinWin.cardX
    y: pinWin.cardY
    width: pinWin.cardWidth
    color: pinWin.bgColor
    borderSpec: pinWin.cardBorderSpec
    radius: pinWin.cornerRadius
    padding: Style.space(10)
    implicitHeight: headerItem.implicitHeight
      + (pinWin.collapsed ? 0 : (1 + Style.space(8) + bodyScroll.height))
      + padding * 2
      + Border.top(borderSpec) + Border.bottom(borderSpec)

    onImplicitHeightChanged: if (pinWin.shown) pinWin.clampCard()

    opacity: pinWin.shown ? 1 : 0
    scale: pinWin.shown ? 1 : 0.96
    Behavior on opacity { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

    FloatingShadow { anchors.fill: parent; radius: cardSurface.radius }

    Column {
      anchors.fill: parent
      anchors.topMargin: cardSurface.contentTopInset
      anchors.rightMargin: cardSurface.contentRightInset
      anchors.bottomMargin: cardSurface.contentBottomInset
      anchors.leftMargin: cardSurface.contentLeftInset
      spacing: Style.space(8)

      // Draggable header bar with title + Copy / Shade / Re-expand / Close
      Item {
        id: headerItem
        width: parent.width
        implicitHeight: Math.max(Style.space(24), headerControls.implicitHeight)

        // Drag handle area (left of action buttons)
        MouseArea {
          id: headerDragArea
          anchors.left: parent.left
          anchors.right: headerControls.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.rightMargin: Style.space(6)
          cursorShape: pinWin.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor

          onPressed: function(mouse) {
            var pt = headerDragArea.mapToItem(dragCatcher, mouse.x, mouse.y)
            pinWin.dragging = true
            pinWin.hasCustomPos = true
            pinWin.dragStartMouseX = pt.x
            pinWin.dragStartMouseY = pt.y
            pinWin.dragStartCardX = pinWin.cardX
            pinWin.dragStartCardY = pinWin.cardY
          }
          onPositionChanged: function(mouse) {
            if (!pinWin.dragging) return
            var pt = headerDragArea.mapToItem(dragCatcher, mouse.x, mouse.y)
            var pos = Logic.clampFloatingPosition(
              pinWin.dragStartCardX + (pt.x - pinWin.dragStartMouseX),
              pinWin.dragStartCardY + (pt.y - pinWin.dragStartMouseY),
              pinWin.cardWidth,
              cardSurface.implicitHeight,
              pinWin.width,
              pinWin.height,
              pinWin.edgeMargin
            )
            pinWin.cardX = pos.x
            pinWin.cardY = pos.y
          }
          onReleased: pinWin.dragging = false
          onCanceled: pinWin.dragging = false
          onDoubleClicked: {
            pinWin.collapsed = !pinWin.collapsed
            Qt.callLater(pinWin.clampCard)
          }
        }

        Row {
          id: headerTitleRow
          anchors.left: parent.left
          anchors.right: headerControls.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          SLRoot.PlainText {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰐃"
            color: pinWin.accentColor
            font.family: pinWin.uiFont
            font.pixelSize: Style.font.bodySmall
          }

          SLRoot.PlainText {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(Style.space(40), headerTitleRow.width - Style.space(22) - (copiedBadge.visible ? (copiedBadge.implicitWidth + Style.space(8)) : 0))
            text: pinWin.titleText
            color: pinWin.fgColor
            font.family: pinWin.uiFont
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Rectangle {
            id: copiedBadge
            visible: pinWin.copiedFlash
            anchors.verticalCenter: parent.verticalCenter
            radius: Math.min(3, pinWin.cornerRadius)
            color: Util.alpha(pinWin.accentColor, 0.20)
            border.width: 1
            border.color: Util.alpha(pinWin.accentColor, 0.50)
            implicitWidth: copiedLbl.implicitWidth + Style.space(8)
            implicitHeight: copiedLbl.implicitHeight + Style.space(3)

            SLRoot.PlainText {
              id: copiedLbl
              anchors.centerIn: parent
              text: pinWin.strings ? pinWin.strings.t("action.copied") : "Copied"
              color: pinWin.accentColor
              font.family: pinWin.uiFont
              font.pixelSize: Math.max(9, Style.font.caption - 1)
              font.bold: true
            }
          }
        }

        Row {
          id: headerControls
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(3)

          Ui.Button {
            foreground: pinWin.fgColor
            visible: pinWin.answerText.length > 0
            iconText: "󰆏"
            fontSize: Style.font.caption
            tooltipText: pinWin.strings ? pinWin.strings.t("action.copy") : "Copy"
            onClicked: {
              pinWin.copyRequested(pinWin.answerText)
              pinWin.flashCopied()
            }
          }

          Ui.Button {
            foreground: pinWin.fgColor
            iconText: pinWin.collapsed ? "󰅃" : "󰅀"
            fontSize: Style.font.caption
            tooltipText: pinWin.collapsed
              ? (pinWin.strings ? pinWin.strings.t("pin.expandBody") : "Expand")
              : (pinWin.strings ? pinWin.strings.t("pin.collapseBody") : "Collapse")
            onClicked: {
              pinWin.collapsed = !pinWin.collapsed
              Qt.callLater(pinWin.clampCard)
            }
          }

          Ui.Button {
            foreground: pinWin.fgColor
            iconText: "󰁌"
            fontSize: Style.font.caption
            tooltipText: pinWin.strings ? pinWin.strings.t("pin.reexpand") : "Open full thread"
            onClicked: pinWin.reexpandRequested(pinWin.pinnedData)
          }

          Ui.Button {
            foreground: pinWin.fgColor
            iconText: "󰅖"
            fontSize: Style.font.caption
            tooltipText: pinWin.strings ? pinWin.strings.t("pin.close") : "Unpin"
            onClicked: pinWin.closeRequested()
          }
        }
      }

      // Subtle hairline divider
      Rectangle {
        visible: !pinWin.collapsed
        width: parent.width
        height: 1
        color: pinWin.hairlineColor
      }

      // Scrollable structured answer body with 1-click code-block copy buttons
      Flickable {
        id: bodyScroll
        visible: !pinWin.collapsed
        width: parent.width
        height: Math.min(pinWin.maxBodyHeight, Math.max(Style.space(42), bodyCol.implicitHeight + Style.space(4)))
        contentWidth: width
        contentHeight: bodyCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        Column {
          id: bodyCol
          width: bodyScroll.width - Style.space(6)
          spacing: Style.space(6)

          Row {
            visible: pinWin.providerText.length > 0 || pinWin.usedWebSearch
            spacing: Style.space(6)

            SLRoot.PlainText {
              visible: pinWin.providerText.length > 0
              anchors.verticalCenter: parent.verticalCenter
              text: pinWin.providerText.toUpperCase()
              color: pinWin.mutedInk
              font.family: pinWin.uiFont
              font.pixelSize: Math.max(9, Style.font.caption - 1)
              font.bold: true
              font.letterSpacing: 0.6
            }

            Rectangle {
              visible: pinWin.usedWebSearch
              anchors.verticalCenter: parent.verticalCenter
              radius: Math.min(3, pinWin.cornerRadius)
              color: Util.alpha(pinWin.accentColor, 0.16)
              border.width: 1
              border.color: Util.alpha(pinWin.accentColor, 0.42)
              implicitWidth: pinWebLbl.implicitWidth + Style.space(8)
              implicitHeight: pinWebLbl.implicitHeight + Style.space(2)

              SLRoot.PlainText {
                id: pinWebLbl
                anchors.centerIn: parent
                text: "󰖟 " + (pinWin.strings ? pinWin.strings.t("status.webGrounded") : "WEB")
                color: pinWin.accentColor
                font.family: pinWin.uiFont
                font.pixelSize: Math.max(9, Style.font.caption - 1)
                font.bold: true
              }
            }
          }

          AnswerBlocks {
            width: bodyCol.width
            blocks: pinWin.answerBlocks
            fgColor: pinWin.fgColor
            accentColor: pinWin.accentColor
            hairlineColor: pinWin.hairlineColor
            hoverFill: pinWin.hoverFill
            mutedInk: pinWin.mutedInk
            cornerRadius: pinWin.cornerRadius
            uiFont: pinWin.uiFont
            copyLabel: pinWin.strings ? pinWin.strings.t("action.copy") : "Copy"
            onCopyRequested: function(txt) {
              pinWin.copyRequested(txt)
              pinWin.flashCopied()
            }
          }
        }
      }
    }
  }
}
