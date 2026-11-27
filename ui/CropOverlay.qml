import QtQuick
import qs.Commons
import qs.Commons as Commons
import ".." as SLRoot
import "../ScreenLensLogic.js" as Logic

// Renders one or more locked crop regions with machined corner L-brackets,
// subtle edge resize ticks, live W × H pixel badges, and numbered #N remove
// badges when 2+ regions are pinned.
//
// In single-crop mode, four dim strips frame the cutout so the selected pixels
// stay crystal-clear without fullscreen opaque-region quirks on Wayland.
Item {
  id: cropOverlay

  property var regions: []         // Array of logical { x, y, w, h }
  property var imgCrops: []        // Parallel array of image-pixel { x, y, w, h }
  property int activeIndex: -1
  property int hoverIndex: -1
  property string activeHandle: "" // Active or hovered handle ("nw","n",...,"move","")
  property color scrimColor: "#70101315"
  property color accentColor: "#7aa2f7"
  property color bgColor: "#181a22"
  property color fgColor: "#e6e9f2"
  property int cornerRadius: Style.cornerRadius
  property string uiFont: Style.font.menuFamily
  property string removeTooltip: "Remove region"

  signal removeRequested(int index)

  readonly property int regionCount: Array.isArray(regions) ? regions.length : 0
  readonly property bool multiMode: regionCount > 1
  readonly property var singleRect: regionCount === 1 ? regions[0] : null

  visible: regionCount > 0

  // Single-crop 4-strip dim scrim (keeps cutout 100% crisp and un-dimmed).
  Item {
    anchors.fill: parent
    visible: !!cropOverlay.singleRect
    readonly property real rx: cropOverlay.singleRect ? cropOverlay.singleRect.x : 0
    readonly property real ry: cropOverlay.singleRect ? cropOverlay.singleRect.y : 0
    readonly property real rw: cropOverlay.singleRect ? cropOverlay.singleRect.w : 0
    readonly property real rh: cropOverlay.singleRect ? cropOverlay.singleRect.h : 0

    Rectangle { x: 0; y: 0; width: parent.width; height: Math.max(0, parent.ry); color: cropOverlay.scrimColor }
    Rectangle { x: 0; y: parent.ry + parent.rh; width: parent.width; height: Math.max(0, parent.height - (parent.ry + parent.rh)); color: cropOverlay.scrimColor }
    Rectangle { x: 0; y: parent.ry; width: Math.max(0, parent.rx); height: parent.rh; color: cropOverlay.scrimColor }
    Rectangle { x: parent.rx + parent.rw; y: parent.ry; width: Math.max(0, parent.width - (parent.rx + parent.rw)); height: parent.rh; color: cropOverlay.scrimColor }
  }

  // Render each pinned crop frame, brackets, edge ticks, and floating badge.
  Repeater {
    model: cropOverlay.regionCount
    delegate: Item {
      id: regionItem
      required property int index
      readonly property var rect: (cropOverlay.regions && index < cropOverlay.regions.length) ? cropOverlay.regions[index] : null
      readonly property var crop: (cropOverlay.imgCrops && index < cropOverlay.imgCrops.length) ? cropOverlay.imgCrops[index] : null
      readonly property real rx: rect ? rect.x : 0
      readonly property real ry: rect ? rect.y : 0
      readonly property real rw: rect ? rect.w : 0
      readonly property real rh: rect ? rect.h : 0
      readonly property bool isHighlighted: index === cropOverlay.hoverIndex || index === cropOverlay.activeIndex
      readonly property string litHandle: index === cropOverlay.hoverIndex ? cropOverlay.activeHandle : ""

      visible: !!rect
      anchors.fill: parent

      // Soft outer accent halo around the locked crop cutout.
      Rectangle {
        x: regionItem.rx - 3
        y: regionItem.ry - 3
        width: regionItem.rw + 6
        height: regionItem.rh + 6
        radius: Math.min(6, cropOverlay.cornerRadius + 2)
        color: "transparent"
        border.width: regionItem.isHighlighted ? 5 : 4
        border.color: Util.alpha(cropOverlay.accentColor, regionItem.isHighlighted ? 0.34 : 0.22)
      }

      // Crisp inner hairline + machined corner L-brackets + midpoint edge ticks.
      Rectangle {
        id: frameRect
        x: regionItem.rx
        y: regionItem.ry
        width: regionItem.rw
        height: regionItem.rh
        radius: Math.min(4, cropOverlay.cornerRadius)
        color: regionItem.litHandle === "move" ? Util.alpha(cropOverlay.accentColor, 0.06) : "transparent"
        border.width: 1
        border.color: Util.alpha(cropOverlay.accentColor, regionItem.isHighlighted ? 0.96 : 0.78)

        readonly property real tick: Math.min(18, Math.max(8, Math.min(width / 3, height / 3)))
        readonly property real arm: 3
        readonly property real edgeTickLen: Math.min(18, Math.max(10, Math.min(width, height) * 0.16))
        readonly property real capRadius: Math.min(2, cropOverlay.cornerRadius)

        // Top-left bracket (nw)
        Rectangle {
          x: -1; y: -1; width: frameRect.tick; height: regionItem.litHandle === "nw" ? 4 : frameRect.arm
          radius: frameRect.capRadius; color: cropOverlay.accentColor
        }
        Rectangle {
          x: -1; y: -1; width: regionItem.litHandle === "nw" ? 4 : frameRect.arm; height: frameRect.tick
          radius: frameRect.capRadius; color: cropOverlay.accentColor
        }
        // Top-right bracket (ne)
        Rectangle {
          x: frameRect.width - frameRect.tick + 1; y: -1; width: frameRect.tick; height: regionItem.litHandle === "ne" ? 4 : frameRect.arm
          radius: frameRect.capRadius; color: cropOverlay.accentColor
        }
        Rectangle {
          x: frameRect.width - (regionItem.litHandle === "ne" ? 4 : frameRect.arm) + 1; y: -1; width: regionItem.litHandle === "ne" ? 4 : frameRect.arm; height: frameRect.tick
          radius: frameRect.capRadius; color: cropOverlay.accentColor
        }
        // Bottom-left bracket (sw)
        Rectangle {
          x: -1; y: frameRect.height - (regionItem.litHandle === "sw" ? 4 : frameRect.arm) + 1; width: frameRect.tick; height: regionItem.litHandle === "sw" ? 4 : frameRect.arm
          radius: frameRect.capRadius; color: cropOverlay.accentColor
        }
        Rectangle {
          x: -1; y: frameRect.height - frameRect.tick + 1; width: regionItem.litHandle === "sw" ? 4 : frameRect.arm; height: frameRect.tick
          radius: frameRect.capRadius; color: cropOverlay.accentColor
        }
        // Bottom-right bracket (se)
        Rectangle {
          x: frameRect.width - frameRect.tick + 1; y: frameRect.height - (regionItem.litHandle === "se" ? 4 : frameRect.arm) + 1; width: frameRect.tick; height: regionItem.litHandle === "se" ? 4 : frameRect.arm
          radius: frameRect.capRadius; color: cropOverlay.accentColor
        }
        Rectangle {
          x: frameRect.width - (regionItem.litHandle === "se" ? 4 : frameRect.arm) + 1; y: frameRect.height - frameRect.tick + 1; width: regionItem.litHandle === "se" ? 4 : frameRect.arm; height: frameRect.tick
          radius: frameRect.capRadius; color: cropOverlay.accentColor
        }

        // Subtle midpoint edge grab ticks (N, S, W, E)
        Rectangle {
          visible: frameRect.width >= 56
          x: (frameRect.width - width) / 2
          y: -1
          width: frameRect.edgeTickLen
          height: regionItem.litHandle === "n" ? 4 : 2.5
          radius: 1.5
          color: Util.alpha(cropOverlay.accentColor, regionItem.litHandle === "n" ? 1.0 : 0.72)
        }
        Rectangle {
          visible: frameRect.width >= 56
          x: (frameRect.width - width) / 2
          y: frameRect.height - height + 1
          width: frameRect.edgeTickLen
          height: regionItem.litHandle === "s" ? 4 : 2.5
          radius: 1.5
          color: Util.alpha(cropOverlay.accentColor, regionItem.litHandle === "s" ? 1.0 : 0.72)
        }
        Rectangle {
          visible: frameRect.height >= 56
          x: -1
          y: (frameRect.height - height) / 2
          width: regionItem.litHandle === "w" ? 4 : 2.5
          height: frameRect.edgeTickLen
          radius: 1.5
          color: Util.alpha(cropOverlay.accentColor, regionItem.litHandle === "w" ? 1.0 : 0.72)
        }
        Rectangle {
          visible: frameRect.height >= 56
          x: frameRect.width - width + 1
          y: (frameRect.height - height) / 2
          width: regionItem.litHandle === "e" ? 4 : 2.5
          height: frameRect.edgeTickLen
          radius: 1.5
          color: Util.alpha(cropOverlay.accentColor, regionItem.litHandle === "e" ? 1.0 : 0.72)
        }
      }

      // Compact floating badge tucked at top-left: W × H in single mode,
      // or #N · W × H + removable × button when 2+ regions are pinned.
      Rectangle {
        visible: cropOverlay.multiMode || (!!regionItem.crop && regionItem.rw >= 64)
        x: Logic.clamp(regionItem.rx, Style.gapsOut, Math.max(Style.gapsOut, cropOverlay.width - width - Style.gapsOut))
        y: regionItem.ry > height + Style.space(12) ? (regionItem.ry - height - Style.space(6)) : (regionItem.ry + Style.space(6))
        radius: Math.min(4, cropOverlay.cornerRadius)
        color: Util.alpha(cropOverlay.bgColor, 0.92)
        border.width: 1
        border.color: Util.alpha(cropOverlay.accentColor, regionItem.isHighlighted ? 0.75 : 0.45)
        implicitWidth: badgeRow.implicitWidth + Style.space(12)
        implicitHeight: badgeRow.implicitHeight + Style.space(5)

        Row {
          id: badgeRow
          anchors.centerIn: parent
          spacing: Style.space(6)

          // Numbered pill (#1, #2, ...) shown in multi-region mode
          Rectangle {
            visible: cropOverlay.multiMode
            anchors.verticalCenter: parent.verticalCenter
            radius: Math.min(3, cropOverlay.cornerRadius)
            color: Util.alpha(cropOverlay.accentColor, 0.24)
            implicitWidth: numLabel.implicitWidth + Style.space(8)
            implicitHeight: numLabel.implicitHeight + Style.space(2)

            SLRoot.PlainText {
              id: numLabel
              anchors.centerIn: parent
              text: "#" + (regionItem.index + 1)
              color: cropOverlay.accentColor
              font.family: cropOverlay.uiFont
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          SLRoot.PlainText {
            visible: !!regionItem.crop && (regionItem.rw >= 64 || !cropOverlay.multiMode)
            anchors.verticalCenter: parent.verticalCenter
            text: regionItem.crop
              ? (Commons.I18n.formatNumber(regionItem.crop.w) + " × " + Commons.I18n.formatNumber(regionItem.crop.h))
              : ""
            color: cropOverlay.multiMode ? Util.alpha(cropOverlay.fgColor, 0.84) : cropOverlay.accentColor
            font.family: cropOverlay.uiFont
            font.pixelSize: Style.font.caption
            font.bold: !cropOverlay.multiMode
          }

          // Clickable remove (×) affordance in multi-region mode
          Rectangle {
            visible: cropOverlay.multiMode
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(16)
            height: Style.space(16)
            radius: Math.min(3, cropOverlay.cornerRadius)
            color: rmHover.hovered ? Util.alpha(cropOverlay.accentColor, 0.24) : "transparent"

            SLRoot.PlainText {
              anchors.centerIn: parent
              text: "×"
              color: rmHover.hovered ? cropOverlay.fgColor : Util.alpha(cropOverlay.fgColor, 0.70)
              font.family: cropOverlay.uiFont
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            HoverHandler { id: rmHover; cursorShape: Qt.PointingHandCursor }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: cropOverlay.removeRequested(regionItem.index)
            }
          }
        }
      }
    }
  }
}
