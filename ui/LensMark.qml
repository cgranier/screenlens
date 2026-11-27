import QtQuick
import QtQuick.Shapes
import qs.Commons

// Custom crisp ScreenLens vector viewfinder mark (4 rounded corner brackets +
// center lens dot) drawn on a 24-unit coordinate space via Shape.CurveRenderer.
Shape {
  id: mark

  property real iconSize: Style.bar.iconCanvas
  property color inkColor: "#ffffff"
  property color dotColor: inkColor

  readonly property real u: iconSize / 24.0
  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize
  preferredRendererType: Shape.CurveRenderer
  antialiasing: true

  // Top-left bracket
  ShapePath {
    fillColor: "transparent"
    strokeColor: Util.alpha(mark.inkColor, 0.92)
    strokeWidth: Math.max(1.4, 2.2 * mark.u)
    capStyle: ShapePath.RoundCap
    joinStyle: ShapePath.RoundJoin
    startX: 3.5 * mark.u; startY: 8.5 * mark.u
    PathLine { x: 3.5 * mark.u; y: 5.5 * mark.u }
    PathQuad { x: 5.5 * mark.u; y: 3.5 * mark.u; controlX: 3.5 * mark.u; controlY: 3.5 * mark.u }
    PathLine { x: 8.5 * mark.u; y: 3.5 * mark.u }
  }

  // Top-right bracket
  ShapePath {
    fillColor: "transparent"
    strokeColor: Util.alpha(mark.inkColor, 0.92)
    strokeWidth: Math.max(1.4, 2.2 * mark.u)
    capStyle: ShapePath.RoundCap
    joinStyle: ShapePath.RoundJoin
    startX: 15.5 * mark.u; startY: 3.5 * mark.u
    PathLine { x: 18.5 * mark.u; y: 3.5 * mark.u }
    PathQuad { x: 20.5 * mark.u; y: 5.5 * mark.u; controlX: 20.5 * mark.u; controlY: 3.5 * mark.u }
    PathLine { x: 20.5 * mark.u; y: 8.5 * mark.u }
  }

  // Bottom-left bracket
  ShapePath {
    fillColor: "transparent"
    strokeColor: Util.alpha(mark.inkColor, 0.92)
    strokeWidth: Math.max(1.4, 2.2 * mark.u)
    capStyle: ShapePath.RoundCap
    joinStyle: ShapePath.RoundJoin
    startX: 3.5 * mark.u; startY: 15.5 * mark.u
    PathLine { x: 3.5 * mark.u; y: 18.5 * mark.u }
    PathQuad { x: 5.5 * mark.u; y: 20.5 * mark.u; controlX: 3.5 * mark.u; controlY: 20.5 * mark.u }
    PathLine { x: 8.5 * mark.u; y: 20.5 * mark.u }
  }

  // Bottom-right bracket
  ShapePath {
    fillColor: "transparent"
    strokeColor: Util.alpha(mark.inkColor, 0.92)
    strokeWidth: Math.max(1.4, 2.2 * mark.u)
    capStyle: ShapePath.RoundCap
    joinStyle: ShapePath.RoundJoin
    startX: 15.5 * mark.u; startY: 20.5 * mark.u
    PathLine { x: 18.5 * mark.u; y: 20.5 * mark.u }
    PathQuad { x: 20.5 * mark.u; y: 18.5 * mark.u; controlX: 20.5 * mark.u; controlY: 20.5 * mark.u }
    PathLine { x: 20.5 * mark.u; y: 15.5 * mark.u }
  }

  // Center lens circle
  ShapePath {
    fillColor: mark.dotColor
    strokeColor: "transparent"
    strokeWidth: 0
    PathAngleArc {
      centerX: 12 * mark.u
      centerY: 12 * mark.u
      radiusX: 3.2 * mark.u
      radiusY: 3.2 * mark.u
      startAngle: 0
      sweepAngle: 360
    }
  }
}
