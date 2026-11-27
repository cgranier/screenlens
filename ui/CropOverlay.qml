import QtQuick
import qs.Commons
import qs.Commons as Commons
import ".." as SLRoot
import "../ScreenLensLogic.js" as Logic

// Four dim strips framing the selected region so the cutout stays crystal-clear
// without fullscreen opaque-region quirks on Wayland layer-shell surfaces.
Item {
  id: cropOverlay

  property var selectionRect: null
  property var imgCrop: null
  property color scrimColor: "#70101315"
  property color accentColor: "#7aa2f7"
  property color bgColor: "#181a22"
  property int cornerRadius: Style.cornerRadius
  property string uiFont: Style.font.menuFamily

  visible: !!selectionRect
  readonly property real rx: selectionRect ? selectionRect.x : 0
  readonly property real ry: selectionRect ? selectionRect.y : 0
  readonly property real rw: selectionRect ? selectionRect.w : 0
  readonly property real rh: selectionRect ? selectionRect.h : 0

  Rectangle { x: 0; y: 0; width: parent.width; height: Math.max(0, cropOverlay.ry); color: cropOverlay.scrimColor }
  Rectangle { x: 0; y: cropOverlay.ry + cropOverlay.rh; width: parent.width; height: Math.max(0, parent.height - (cropOverlay.ry + cropOverlay.rh)); color: cropOverlay.scrimColor }
  Rectangle { x: 0; y: cropOverlay.ry; width: Math.max(0, cropOverlay.rx); height: cropOverlay.rh; color: cropOverlay.scrimColor }
  Rectangle { x: cropOverlay.rx + cropOverlay.rw; y: cropOverlay.ry; width: Math.max(0, parent.width - (cropOverlay.rx + cropOverlay.rw)); height: cropOverlay.rh; color: cropOverlay.scrimColor }

  // Soft outer accent halo around the locked crop cutout.
  Rectangle {
    x: cropOverlay.rx - 3
    y: cropOverlay.ry - 3
    width: cropOverlay.rw + 6
    height: cropOverlay.rh + 6
    radius: Math.min(6, cropOverlay.cornerRadius + 2)
    color: "transparent"
    border.width: 4
    border.color: Util.alpha(cropOverlay.accentColor, 0.24)
  }

  // Crisp inner hairline + machined corner L-brackets.
  Rectangle {
    id: frameRect
    x: cropOverlay.rx
    y: cropOverlay.ry
    width: cropOverlay.rw
    height: cropOverlay.rh
    radius: Math.min(4, cropOverlay.cornerRadius)
    color: "transparent"
    border.width: 1
    border.color: Util.alpha(cropOverlay.accentColor, 0.88)

    readonly property real tick: Math.min(18, Math.max(8, Math.min(width / 3, height / 3)))
    readonly property real arm: 3
    readonly property real capRadius: Math.min(2, cropOverlay.cornerRadius)

    // Top-left bracket
    Rectangle { x: -1; y: -1; width: frameRect.tick; height: frameRect.arm; radius: frameRect.capRadius; color: cropOverlay.accentColor }
    Rectangle { x: -1; y: -1; width: frameRect.arm; height: frameRect.tick; radius: frameRect.capRadius; color: cropOverlay.accentColor }
    // Top-right bracket
    Rectangle { x: frameRect.width - frameRect.tick + 1; y: -1; width: frameRect.tick; height: frameRect.arm; radius: frameRect.capRadius; color: cropOverlay.accentColor }
    Rectangle { x: frameRect.width - frameRect.arm + 1; y: -1; width: frameRect.arm; height: frameRect.tick; radius: frameRect.capRadius; color: cropOverlay.accentColor }
    // Bottom-left bracket
    Rectangle { x: -1; y: frameRect.height - frameRect.arm + 1; width: frameRect.tick; height: frameRect.arm; radius: frameRect.capRadius; color: cropOverlay.accentColor }
    Rectangle { x: -1; y: frameRect.height - frameRect.tick + 1; width: frameRect.arm; height: frameRect.tick; radius: frameRect.capRadius; color: cropOverlay.accentColor }
    // Bottom-right bracket
    Rectangle { x: frameRect.width - frameRect.tick + 1; y: frameRect.height - frameRect.arm + 1; width: frameRect.tick; height: frameRect.arm; radius: frameRect.capRadius; color: cropOverlay.accentColor }
    Rectangle { x: frameRect.width - frameRect.arm + 1; y: frameRect.height - frameRect.tick + 1; width: frameRect.arm; height: frameRect.tick; radius: frameRect.capRadius; color: cropOverlay.accentColor }
  }

  // Compact floating pixel dimension badge tucked at top-left of the crop.
  Rectangle {
    visible: !!cropOverlay.imgCrop && cropOverlay.rw >= 64
    x: Logic.clamp(cropOverlay.rx, Style.gapsOut, Math.max(Style.gapsOut, cropOverlay.width - width - Style.gapsOut))
    y: cropOverlay.ry > height + Style.space(12) ? (cropOverlay.ry - height - Style.space(6)) : (cropOverlay.ry + Style.space(6))
    radius: Math.min(4, cropOverlay.cornerRadius)
    color: Util.alpha(cropOverlay.bgColor, 0.90)
    border.width: 1
    border.color: Util.alpha(cropOverlay.accentColor, 0.45)
    implicitWidth: dimLabel.implicitWidth + Style.space(12)
    implicitHeight: dimLabel.implicitHeight + Style.space(5)

    SLRoot.PlainText {
      id: dimLabel
      anchors.centerIn: parent
      text: cropOverlay.imgCrop
        ? (Commons.I18n.formatNumber(cropOverlay.imgCrop.w) + " × " + Commons.I18n.formatNumber(cropOverlay.imgCrop.h))
        : ""
      color: cropOverlay.accentColor
      font.family: cropOverlay.uiFont
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}
