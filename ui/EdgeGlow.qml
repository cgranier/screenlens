import QtQuick
import qs.Commons

// Superwhisper-inspired feathered inward-fading edge glow around the active monitor.
// Uses 4 directional GPU gradients + a crisp luminous inner rim (zero Canvas/FBO).
Item {
  id: edgeGlow

  property bool opened: false
  property color glowColor: "#7aa2f7"
  property bool activeBoost: false

  readonly property real depth: activeBoost ? Style.space(42) : Style.space(32)
  property real breath: 1.0

  Behavior on glowColor {
    ColorAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
  }

  SequentialAnimation on breath {
    running: edgeGlow.opened && !Style.reduceMotion
    loops: Animation.Infinite
    NumberAnimation { to: 0.74; duration: Style.duration(1500); easing.type: Easing.InOutSine }
    NumberAnimation { to: 1.0; duration: Style.duration(1500); easing.type: Easing.InOutSine }
  }

  opacity: opened ? ((activeBoost ? 1.0 : 0.84) * (Style.reduceMotion ? 1.0 : breath)) : 0
  Behavior on opacity {
    NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
  }

  // Top feathered glow
  Rectangle {
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: edgeGlow.depth
    gradient: Gradient {
      orientation: Gradient.Vertical
      GradientStop { position: 0.0; color: Util.alpha(edgeGlow.glowColor, 0.34) }
      GradientStop { position: 0.22; color: Util.alpha(edgeGlow.glowColor, 0.14) }
      GradientStop { position: 0.58; color: Util.alpha(edgeGlow.glowColor, 0.035) }
      GradientStop { position: 1.0; color: "transparent" }
    }
  }

  // Bottom feathered glow
  Rectangle {
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    height: edgeGlow.depth
    gradient: Gradient {
      orientation: Gradient.Vertical
      GradientStop { position: 0.0; color: "transparent" }
      GradientStop { position: 0.42; color: Util.alpha(edgeGlow.glowColor, 0.035) }
      GradientStop { position: 0.78; color: Util.alpha(edgeGlow.glowColor, 0.14) }
      GradientStop { position: 1.0; color: Util.alpha(edgeGlow.glowColor, 0.34) }
    }
  }

  // Left feathered glow
  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: edgeGlow.depth
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0.0; color: Util.alpha(edgeGlow.glowColor, 0.34) }
      GradientStop { position: 0.22; color: Util.alpha(edgeGlow.glowColor, 0.14) }
      GradientStop { position: 0.58; color: Util.alpha(edgeGlow.glowColor, 0.035) }
      GradientStop { position: 1.0; color: "transparent" }
    }
  }

  // Right feathered glow
  Rectangle {
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: edgeGlow.depth
    gradient: Gradient {
      orientation: Gradient.Horizontal
      GradientStop { position: 0.0; color: "transparent" }
      GradientStop { position: 0.42; color: Util.alpha(edgeGlow.glowColor, 0.035) }
      GradientStop { position: 0.78; color: Util.alpha(edgeGlow.glowColor, 0.14) }
      GradientStop { position: 1.0; color: Util.alpha(edgeGlow.glowColor, 0.34) }
    }
  }

  // Crisp luminous perimeter hairline
  Rectangle {
    anchors.fill: parent
    color: "transparent"
    border.width: 2
    border.color: Util.alpha(edgeGlow.glowColor, 0.62)
  }
}
