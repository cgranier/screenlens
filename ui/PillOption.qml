import QtQuick
import qs.Commons
import ".." as SLRoot

Rectangle {
  id: pill

  property string label: ""
  property string icon: ""
  property bool active: false
  property bool showDot: false
  property bool dotReady: false
  property real fontSize: Style.font.bodySmall

  property color fgColor: "#e6e9f2"
  property color accentColor: "#7aa2f7"
  property color secondaryInk: Util.alpha(fgColor, 0.72)
  property color mutedInk: Util.alpha(fgColor, 0.50)
  property color restFill: Util.alpha(fgColor, 0.045)
  property color hoverFill: Util.alpha(fgColor, 0.09)
  property color cardBorder: Util.alpha(fgColor, 0.08)
  property int cornerRadius: Style.cornerRadius
  property string uiFont: Style.font.family

  signal clicked()

  radius: Math.min(4, cornerRadius)
  color: active
    ? Util.alpha(accentColor, 0.18)
    : (pillHover.hovered ? hoverFill : restFill)
  border.width: 1
  border.color: active
    ? Util.alpha(accentColor, 0.65)
    : (pillHover.hovered ? Util.alpha(fgColor, 0.22) : cardBorder)
  implicitWidth: pillRow.implicitWidth + Style.space(16)
  implicitHeight: Style.space(26)

  Row {
    id: pillRow
    anchors.centerIn: parent
    spacing: Style.space(5)

    Rectangle {
      visible: pill.showDot
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(6)
      height: Style.space(6)
      radius: width / 2
      color: pill.dotReady ? pill.accentColor : "transparent"
      border.width: pill.dotReady ? 0 : 1
      border.color: pill.mutedInk
    }

    SLRoot.PlainText {
      visible: pill.icon.length > 0
      anchors.verticalCenter: parent.verticalCenter
      text: pill.icon
      color: pill.active ? pill.accentColor : pill.secondaryInk
      font.family: pill.uiFont
      font.pixelSize: pill.fontSize
    }

    SLRoot.PlainText {
      anchors.verticalCenter: parent.verticalCenter
      text: pill.label
      color: pill.active ? pill.fgColor : pill.secondaryInk
      font.family: pill.uiFont
      font.pixelSize: pill.fontSize
      font.bold: pill.active
    }
  }

  HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: pill.clicked()
  }
}
