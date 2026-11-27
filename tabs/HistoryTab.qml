import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import ".." as SLRoot
import "../ScreenLensLogic.js" as Logic
import "../ui" as SLUi

Column {
  id: tab

  required property var panel
  required property var strings

  readonly property var filteredSessions: Logic.filterHistorySessions(tab.panel.historySessions, tab.panel.historyQuery)
  readonly property bool historyEnabled: tab.panel.cfgVal("historyEnabled", true) !== false

  spacing: Style.space(10)

  // Disabled banner with quick 1-click re-enable
  SLUi.SectionCard {
    visible: !tab.historyEnabled
    width: parent.width
    fill: Util.alpha(tab.panel.accentColor, 0.08)
    stroke: Util.alpha(tab.panel.accentColor, 0.32)
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: Math.max(Style.space(40), disabledRow.implicitHeight + Style.space(14))

    Item {
      id: disabledRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(disabledText.implicitHeight, enableHistBtn.implicitHeight)

      SLRoot.PlainText {
        id: disabledText
        anchors.left: parent.left
        anchors.right: enableHistBtn.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: tab.strings.t("settings.historyDisabledNotice")
        color: tab.panel.secondaryInk
        font.family: tab.panel.uiFont
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      Ui.Button {
        id: enableHistBtn
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        foreground: tab.panel.fgColor
        text: tab.strings.t("settings.historyEnableNow")
        fontSize: Style.font.caption
        bordered: true
        selected: true
        onClicked: tab.panel.patchConfig({ historyEnabled: true })
      }
    }
  }

  // Search input + count + two-step Clear All
  Row {
    id: searchRow
    width: parent.width
    spacing: Style.space(6)

    Ui.TextField {
      id: searchInput
      width: searchRow.width - (clearAllBtn.visible ? (clearAllBtn.implicitWidth + searchRow.spacing) : 0)
      text: tab.panel.historyQuery
      placeholderText: tab.strings.t("settings.historySearchPlaceholder")
      foreground: tab.panel.fgColor
      accent: tab.panel.accentColor
      onTextEdited: tab.panel.historyQuery = text
      Keys.onEscapePressed: {
        if (text.length > 0) {
          text = ""
          tab.panel.historyQuery = ""
        } else {
          tab.panel.close()
        }
      }
    }

    Ui.Button {
      id: clearAllBtn
      visible: tab.panel.historySessions.length > 0
      anchors.verticalCenter: parent.verticalCenter
      foreground: tab.panel.confirmClearAll ? tab.panel.urgentColor : tab.panel.fgColor
      text: tab.panel.confirmClearAll
        ? tab.strings.t("settings.historyConfirmClear")
        : tab.strings.t("settings.historyClearAll")
      iconText: "󰆴"
      fontSize: Style.font.caption
      bordered: true
      onClicked: tab.panel.requestClearAllHistory()
    }
  }

  Item {
    width: parent.width
    implicitHeight: countText.implicitHeight

    SLRoot.PlainText {
      id: countText
      anchors.left: parent.left
      text: tab.strings.tn("settings.historyCount", tab.filteredSessions.length)
        .arg(Commons.I18n.formatNumber(tab.filteredSessions.length))
      color: tab.panel.mutedInk
      font.family: tab.panel.uiFont
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    SLRoot.PlainText {
      visible: tab.panel.historySessions.length > 0
      anchors.right: parent.right
      text: "0600 ~/.local/state/omarchy/screenlens"
      color: Util.alpha(tab.panel.fgColor, 0.35)
      font.family: tab.panel.uiFont
      font.pixelSize: Math.max(9, Style.font.caption - 1)
    }
  }

  // Empty state
  SLUi.SectionCard {
    visible: tab.filteredSessions.length === 0
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: emptyText.implicitHeight + Style.space(28)

    SLRoot.PlainText {
      id: emptyText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(14)
      anchors.rightMargin: Style.space(14)
      text: tab.panel.historySessions.length > 0
        ? tab.strings.t("settings.historyNoMatch")
        : tab.strings.t("settings.historyEmpty")
      color: tab.panel.mutedInk
      font.family: tab.panel.uiFont
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
    }
  }

  // Saved session cards
  Column {
    width: parent.width
    spacing: Style.space(8)

    Repeater {
      model: tab.filteredSessions
      delegate: SLUi.SectionCard {
        id: sessCard
        required property var modelData
        readonly property var preview: Logic.sessionPreview(modelData)
        readonly property bool expanded: tab.panel.selectedHistoryId === modelData.id
        readonly property bool confirmingDelete: tab.panel.confirmDeleteId === modelData.id
        readonly property bool hasThumb: !!modelData.thumbPath

        width: parent.width
        fill: expanded ? Util.alpha(tab.panel.accentColor, 0.06) : tab.panel.cardFill
        stroke: expanded ? Util.alpha(tab.panel.accentColor, 0.45) : (cardHover.hovered ? Util.alpha(tab.panel.fgColor, 0.20) : tab.panel.cardBorder)
        cornerRadius: tab.panel.cornerRadius
        implicitHeight: cardInnerCol.implicitHeight

        Column {
          id: cardInnerCol
          width: parent.width

          // Clickable summary header row
          Item {
            width: parent.width
            implicitHeight: Math.max(Style.space(64), summaryMetaCol.implicitHeight + Style.space(16))

            HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                tab.panel.confirmDeleteId = ""
                tab.panel.selectedHistoryId = sessCard.expanded ? "" : String(sessCard.modelData.id || "")
              }
            }

            // Compact rounded thumbnail
            Rectangle {
              id: thumbFrame
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(76)
              height: Style.space(48)
              radius: Math.min(4, tab.panel.cornerRadius)
              color: tab.panel.restFill
              border.width: 1
              border.color: tab.panel.cardBorder
              clip: true

              Image {
                id: thumbImg
                anchors.fill: parent
                visible: sessCard.hasThumb && status === Image.Ready
                source: sessCard.hasThumb ? ("file://" + sessCard.modelData.thumbPath) : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                smooth: true
              }

              SLRoot.PlainText {
                anchors.centerIn: parent
                visible: !sessCard.hasThumb || thumbImg.status !== Image.Ready
                text: "󰋚"
                color: tab.panel.mutedInk
                font.family: tab.panel.uiFont
                font.pixelSize: Style.font.subtitle
              }
            }

            // Title, timestamp, app/provider, snippet
            Column {
              id: summaryMetaCol
              anchors.left: thumbFrame.right
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Item {
                width: parent.width
                implicitHeight: Math.max(titleLbl.implicitHeight, timeLbl.implicitHeight)

                SLRoot.PlainText {
                  id: titleLbl
                  anchors.left: parent.left
                  anchors.right: timeLbl.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: sessCard.preview.title
                  color: tab.panel.fgColor
                  font.family: tab.panel.uiFont
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                SLRoot.PlainText {
                  id: timeLbl
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: Logic.formatRelativeTime(sessCard.modelData.updatedAt)
                  color: tab.panel.mutedInk
                  font.family: tab.panel.uiFont
                  font.pixelSize: Math.max(9, Style.font.caption - 1)
                }
              }

              SLRoot.PlainText {
                width: parent.width
                text: {
                  var parts = []
                  if (sessCard.modelData.windowClass) parts.push(String(sessCard.modelData.windowClass))
                  if (sessCard.modelData.providerLabel) parts.push(String(sessCard.modelData.providerLabel))
                  return parts.join(" · ")
                }
                visible: text.length > 0
                color: tab.panel.accentColor
                font.family: tab.panel.uiFont
                font.pixelSize: Math.max(9, Style.font.caption - 1)
                elide: Text.ElideRight
              }

              SLRoot.PlainText {
                width: parent.width
                visible: !sessCard.expanded && sessCard.preview.snippet.length > 0
                text: sessCard.preview.snippet
                color: tab.panel.secondaryInk
                font.family: tab.panel.uiFont
                font.pixelSize: Style.font.caption
                maximumLineCount: 2
                wrapMode: Text.Wrap
                elide: Text.ElideRight
              }
            }
          }

          // Expanded detail drawer: full conversation preview + actions
          Column {
            visible: sessCard.expanded
            width: parent.width

            SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

            Item {
              width: parent.width
              implicitHeight: Math.min(Style.space(220), detailCol.implicitHeight + Style.space(16))

              Flickable {
                id: detailFlick
                anchors.fill: parent
                anchors.margins: Style.space(8)
                contentWidth: width
                contentHeight: detailCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: detailCol
                  width: detailFlick.width
                  spacing: Style.space(6)

                  Repeater {
                    model: Array.isArray(sessCard.modelData.messages) ? sessCard.modelData.messages : []
                    delegate: Rectangle {
                      required property var modelData
                      readonly property bool isUser: modelData.role === "user"
                      width: detailCol.width
                      radius: Math.min(4, tab.panel.cornerRadius)
                      color: isUser ? Util.alpha(tab.panel.accentColor, 0.10) : Util.alpha(tab.panel.fgColor, 0.03)
                      border.width: 1
                      border.color: isUser ? Util.alpha(tab.panel.accentColor, 0.24) : tab.panel.rowDivider
                      implicitHeight: (isUser ? histUserText.implicitHeight : histAssistantBlocks.implicitHeight) + Style.space(12)

                      SLRoot.PlainText {
                        id: histUserText
                        visible: parent.isUser
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Style.space(6)
                        text: String(modelData.text || "")
                        color: tab.panel.fgColor
                        font.family: tab.panel.uiFont
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        wrapMode: Text.Wrap
                      }

                      SLUi.AnswerBlocks {
                        id: histAssistantBlocks
                        visible: !parent.isUser
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Style.space(6)
                        blocks: parent.isUser ? [] : Logic.parseAnswerBlocks(modelData.text)
                        fgColor: tab.panel.fgColor
                        accentColor: tab.panel.accentColor
                        hairlineColor: tab.panel.hairline
                        hoverFill: tab.panel.hoverFill
                        mutedInk: tab.panel.mutedInk
                        cornerRadius: tab.panel.cornerRadius
                        uiFont: tab.panel.uiFont
                        copyLabel: tab.strings.t("action.copy")
                        onCopyRequested: function(txt) { tab.panel.copyText(txt) }
                      }
                    }
                  }
                }
              }
            }

            SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

            Item {
              width: parent.width
              implicitHeight: actionRow.implicitHeight + Style.space(14)

              Row {
                id: actionRow
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Ui.Button {
                  foreground: tab.panel.fgColor
                  text: tab.strings.t("settings.historyResume")
                  iconText: "󰑙"
                  fontSize: Style.font.caption
                  bordered: true
                  selected: true
                  onClicked: tab.panel.resumeHistorySession(sessCard.modelData)
                }

                Ui.Button {
                  foreground: tab.panel.fgColor
                  visible: sessCard.preview.latestAnswer.length > 0
                  text: tab.strings.t("action.copy")
                  iconText: "󰆏"
                  fontSize: Style.font.caption
                  bordered: true
                  onClicked: tab.panel.copyText(sessCard.preview.latestAnswer)
                }

                Ui.Button {
                  foreground: tab.panel.fgColor
                  text: tab.strings.t("settings.historyAgent")
                  iconText: "󰆍"
                  fontSize: Style.font.caption
                  bordered: true
                  onClicked: tab.panel.handoffHistorySession(sessCard.modelData)
                }
              }

              Ui.Button {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                foreground: sessCard.confirmingDelete ? tab.panel.urgentColor : tab.panel.mutedInk
                text: sessCard.confirmingDelete
                  ? tab.strings.t("settings.historyConfirmDelete")
                  : tab.strings.t("settings.historyDelete")
                iconText: "󰆴"
                fontSize: Style.font.caption
                bordered: true
                onClicked: tab.panel.requestDeleteHistorySession(String(sessCard.modelData.id || ""))
              }
            }
          }
        }
      }
    }
  }
}
