import QtQuick
import qs.Commons
import qs.Ui as Ui
import ".." as SLRoot
import "../ui" as SLUi

Column {
  id: tab

  required property var panel
  required property var strings

  spacing: Style.space(10)

  SLUi.SectionLabel {
    text: tab.strings.t("settings.translateLanguage").toUpperCase()
    labelColor: tab.panel.mutedInk
    uiFont: tab.panel.uiFont
  }

  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: translateCardCol.implicitHeight

    Column {
      id: translateCardCol
      width: parent.width

      Item {
        width: parent.width
        implicitHeight: translateFlow.implicitHeight + Style.space(16)

        Flow {
          id: translateFlow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(8)
          spacing: Style.space(5)

          Repeater {
            model: ["English", "Spanish", "French", "German", "Portuguese", "Italian", "Japanese", "Chinese", "Korean"]
            delegate: SLUi.PillOption {
              required property string modelData
              label: modelData
              fgColor: tab.panel.fgColor
              accentColor: tab.panel.accentColor
              cornerRadius: tab.panel.cornerRadius
              uiFont: tab.panel.uiFont
              active: tab.panel.cfgVal("translateLanguage", "English") === modelData
              onClicked: tab.panel.patchConfig({ translateLanguage: modelData })
            }
          }
        }
      }

      SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

      Item {
        width: parent.width
        implicitHeight: customLangRow.implicitHeight + Style.space(16)

        Row {
          id: customLangRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(6)

          Ui.TextField {
            width: customLangRow.width - saveCustomLangBtn.implicitWidth - customLangRow.spacing
            text: tab.panel.customTranslateLangDraft
            placeholderText: tab.strings.t("settings.customLangPlaceholder")
            foreground: tab.panel.fgColor
            accent: tab.panel.accentColor
            onTextEdited: tab.panel.customTranslateLangDraft = text
            onAccepted: {
              var lang = tab.panel.customTranslateLangDraft.trim()
              if (lang) {
                tab.panel.patchConfig({ translateLanguage: lang })
                tab.panel.customTranslateLangDraft = ""
              }
            }
            Keys.onEscapePressed: tab.panel.close()
          }

          Ui.Button {
            id: saveCustomLangBtn
            foreground: tab.panel.fgColor
            anchors.verticalCenter: parent.verticalCenter
            text: tab.strings.t("settings.save")
            fontSize: Style.font.caption
            bordered: true
            onClicked: {
              var lang = tab.panel.customTranslateLangDraft.trim()
              if (lang) {
                tab.panel.patchConfig({ translateLanguage: lang })
                tab.panel.customTranslateLangDraft = ""
              }
            }
          }
        }
      }
    }
  }

  SLUi.SectionLabel {
    text: tab.strings.t("settings.ocrLanguages").toUpperCase()
    labelColor: tab.panel.mutedInk
    uiFont: tab.panel.uiFont
  }

  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: ocrCardCol.implicitHeight

    Column {
      id: ocrCardCol
      width: parent.width

      Column {
        width: parent.width - Style.space(16)
        x: Style.space(8)
        topPadding: Style.space(8)
        bottomPadding: Style.space(8)
        spacing: Style.space(6)

        SLRoot.PlainText {
          width: parent.width
          text: tab.strings.t("settings.ocrToggleHint")
          color: tab.panel.secondaryInk
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Flow {
          width: parent.width
          spacing: Style.space(5)

          Repeater {
            model: tab.panel.ocrInstalled
            delegate: SLUi.PillOption {
              required property var modelData
              label: modelData.name + " (" + modelData.code + ")"
              icon: tab.panel.isOcrLangActive(modelData.code) ? "󰄬" : ""
              fgColor: tab.panel.fgColor
              accentColor: tab.panel.accentColor
              cornerRadius: tab.panel.cornerRadius
              uiFont: tab.panel.uiFont
              active: tab.panel.isOcrLangActive(modelData.code)
              onClicked: tab.panel.toggleOcrLang(modelData.code)
            }
          }
        }
      }

      SLUi.CardDivider {
        visible: tab.panel.ocrAvailable.length > 0
        width: parent.width
        dividerColor: tab.panel.rowDivider
      }

      Column {
        visible: tab.panel.ocrAvailable.length > 0
        width: parent.width - Style.space(16)
        x: Style.space(8)
        topPadding: Style.space(8)
        bottomPadding: Style.space(8)
        spacing: Style.space(6)

        SLRoot.PlainText {
          text: tab.strings.t("settings.ocrDownloadSection")
          color: tab.panel.secondaryInk
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Row {
          id: ocrInstallRow
          width: parent.width
          spacing: Style.space(6)

          Ui.Dropdown {
            width: ocrInstallRow.width - ocrInstallBtn.implicitWidth - ocrInstallRow.spacing
            showLabel: false
            value: tab.panel.selectedOcrInstallCode
            options: tab.panel.ocrAvailableOptions()
            foreground: tab.panel.fgColor
            background: tab.panel.bgColor
            accent: tab.panel.accentColor
            onChanged: function(nextCode) {
              tab.panel.selectedOcrInstallCode = nextCode
            }
          }

          Ui.Button {
            id: ocrInstallBtn
            foreground: tab.panel.fgColor
            anchors.verticalCenter: parent.verticalCenter
            text: tab.panel.installingOcrPack ? tab.strings.t("settings.installing") : tab.strings.t("settings.installPack")
            iconText: "󰇚"
            iconSpinning: tab.panel.installingOcrPack
            fontSize: Style.font.caption
            bordered: true
            selected: true
            onClicked: tab.panel.installSelectedOcrPack()
          }
        }

        SLRoot.PlainText {
          visible: tab.panel.selectedOcrInstallCode.length > 0
          width: parent.width
          text: tab.strings.t("settings.ocrCliHint").arg("omarchy pkg add tesseract-data-" + tab.panel.selectedOcrInstallCode)
          color: tab.panel.mutedInk
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }
    }
  }
}
