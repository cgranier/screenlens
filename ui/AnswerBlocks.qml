import QtQuick
import qs.Commons
import ".." as SLRoot

// PlainText-safe structured answer block renderer (headings, bold subheadings,
// accent bullets, paragraphs, and recessed code blocks with one-click Copy).
Column {
  id: blockCol

  property var blocks: []
  property color fgColor: "#e6e9f2"
  property color accentColor: "#7aa2f7"
  property color hairlineColor: Util.alpha(fgColor, 0.14)
  property color hoverFill: Util.alpha(fgColor, 0.10)
  property color mutedInk: Util.alpha(fgColor, 0.56)
  property int cornerRadius: Style.cornerRadius
  property string uiFont: Style.font.menuFamily
  property string copyLabel: "Copy"

  signal copyRequested(string text)

  spacing: Style.spacing.xs

  Repeater {
    model: blockCol.blocks
    delegate: Item {
      id: blockItem
      required property var modelData
      width: blockCol.width
      implicitHeight: headingBlock.visible ? headingBlock.implicitHeight
        : (subheadingBlock.visible ? subheadingBlock.implicitHeight
        : (bulletBlock.visible ? bulletBlock.implicitHeight
        : (codeBlock.visible ? codeBlock.implicitHeight : paraBlock.implicitHeight)))

      SLRoot.PlainText {
        id: headingBlock
        visible: blockItem.modelData.kind === "heading"
        width: parent.width
        topPadding: Style.space(2)
        text: blockItem.modelData.text
        color: blockCol.fgColor
        font.family: blockCol.uiFont
        font.pixelSize: Style.font.subtitle
        font.bold: true
        wrapMode: Text.Wrap
      }

      SLRoot.PlainText {
        id: subheadingBlock
        visible: blockItem.modelData.kind === "subheading"
        width: parent.width
        topPadding: Style.space(2)
        text: blockItem.modelData.text
        color: blockCol.fgColor
        font.family: blockCol.uiFont
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.Wrap
      }

      Item {
        id: bulletBlock
        visible: blockItem.modelData.kind === "bullet"
        width: parent.width
        implicitHeight: bulletBody.implicitHeight

        SLRoot.PlainText {
          id: bulletMarker
          x: Style.space(2)
          y: 0
          text: blockItem.modelData.lang || "•"
          color: blockCol.accentColor
          font.family: blockCol.uiFont
          font.pixelSize: Style.font.body
          font.bold: true
        }

        SLRoot.PlainText {
          id: bulletBody
          anchors.left: bulletMarker.right
          anchors.leftMargin: Style.space(7)
          anchors.right: parent.right
          text: blockItem.modelData.text
          color: blockCol.fgColor
          font.family: blockCol.uiFont
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }
      }

      Rectangle {
        id: codeBlock
        visible: blockItem.modelData.kind === "code"
        width: parent.width
        radius: Math.min(4, blockCol.cornerRadius)
        color: Util.alpha(blockCol.fgColor, 0.07)
        border.width: 1
        border.color: blockCol.hairlineColor
        implicitHeight: codeHeader.implicitHeight + codeContent.implicitHeight + Style.spacing.sm * 2 + Style.space(6)

        Item {
          id: codeHeader
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: Style.spacing.sm
          anchors.rightMargin: Style.spacing.xs
          anchors.topMargin: Style.space(4)
          implicitHeight: Math.max(codeLangLabel.implicitHeight, copyCodeBtn.implicitHeight)

          SLRoot.PlainText {
            id: codeLangLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: (blockItem.modelData.lang || "code").toUpperCase()
            color: blockCol.mutedInk
            font.family: blockCol.uiFont
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 0.8
          }

          Rectangle {
            id: copyCodeBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            radius: Math.min(3, blockCol.cornerRadius)
            color: copyCodeHover.hovered ? blockCol.hoverFill : "transparent"
            border.width: copyCodeHover.hovered ? 1 : 0
            border.color: blockCol.hairlineColor
            implicitWidth: copyCodeRow.implicitWidth + Style.space(10)
            implicitHeight: copyCodeRow.implicitHeight + Style.space(4)

            Row {
              id: copyCodeRow
              anchors.centerIn: parent
              spacing: Style.space(4)

              SLRoot.PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: "󰆏"
                color: copyCodeHover.hovered ? blockCol.accentColor : blockCol.mutedInk
                font.family: blockCol.uiFont
                font.pixelSize: Style.font.caption
              }

              SLRoot.PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: blockCol.copyLabel
                color: copyCodeHover.hovered ? blockCol.fgColor : blockCol.mutedInk
                font.family: blockCol.uiFont
                font.pixelSize: Style.font.caption
              }
            }

            HoverHandler { id: copyCodeHover; cursorShape: Qt.PointingHandCursor }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: blockCol.copyRequested(blockItem.modelData.text)
            }
          }
        }

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: codeHeader.bottom
          anchors.topMargin: Style.space(3)
          height: 1
          color: Util.alpha(blockCol.fgColor, 0.08)
        }

        SLRoot.PlainText {
          id: codeContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: codeHeader.bottom
          anchors.topMargin: Style.spacing.sm + Style.space(2)
          anchors.leftMargin: Style.spacing.sm
          anchors.rightMargin: Style.spacing.sm
          text: blockItem.modelData.text
          color: blockCol.fgColor
          font.family: blockCol.uiFont
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WrapAnywhere
        }
      }

      SLRoot.PlainText {
        id: paraBlock
        visible: blockItem.modelData.kind !== "heading"
          && blockItem.modelData.kind !== "subheading"
          && blockItem.modelData.kind !== "bullet"
          && blockItem.modelData.kind !== "code"
        width: parent.width
        text: blockItem.modelData.text
        color: blockCol.fgColor
        font.family: blockCol.uiFont
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
      }
    }
  }
}
