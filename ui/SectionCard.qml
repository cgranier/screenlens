import QtQuick
import qs.Commons

Rectangle {
  property color fill: "#08ffffff"
  property color stroke: "#14ffffff"
  property int cornerRadius: Style.cornerRadius

  radius: cornerRadius
  color: fill
  border.width: 1
  border.color: stroke
  clip: true
}
