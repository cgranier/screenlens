import QtQuick
import qs.Commons
import ".." as SLRoot

Rectangle {
  id: cap

  property string label: ""
  property color fgColor: "#e6e9f2"
  property color capTextColor: Util.alpha(fgColor, 0.72)
  property color capBg: Util.alpha(fgColor, 0.06)
  property color capBorder: Util.alpha(fgColor, 0.16)
  property int cornerRadius: Style.cornerRadius
  property string uiFont: Style.font.family

  radius: Math.min(3, cornerRadius)
  color: capBg
  border.width: 1
  border.color: capBorder
  implicitWidth: capText.implicitWidth + Style.space(8)
  implicitHeight: capText.implicitHeight + Style.space(3)

  SLRoot.PlainText {
    id: capText
    anchors.centerIn: parent
    text: cap.label
    color: cap.capTextColor
    font.family: cap.uiFont
    font.pixelSize: Math.max(9, Style.font.caption - 1)
  }
}
