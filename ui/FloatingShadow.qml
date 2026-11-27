import QtQuick
import qs.Commons

// Two-layer subtle offset black depth shadow for floating HUD cards (no FBO/blur quirks).
Item {
  id: shadowItem

  property real radius: Style.cornerRadius
  z: -1

  Rectangle {
    x: 0
    y: Style.space(6)
    width: parent.width
    height: parent.height
    radius: shadowItem.radius
    color: "#22000000"
  }

  Rectangle {
    x: 0
    y: Style.space(2)
    width: parent.width
    height: parent.height
    radius: shadowItem.radius
    color: "#36000000"
  }
}
