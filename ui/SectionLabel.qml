import QtQuick
import qs.Commons
import ".." as SLRoot

SLRoot.PlainText {
  property color labelColor: "#888c99"
  property string uiFont: Style.font.family

  color: labelColor
  font.family: uiFont
  font.pixelSize: Style.font.caption
  font.bold: true
  font.letterSpacing: 1.0
  leftPadding: Style.space(2)
}
