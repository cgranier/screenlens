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
    text: tab.strings.t("settings.section.keybind").toUpperCase()
    labelColor: tab.panel.mutedInk
    uiFont: tab.panel.uiFont
  }

  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: hotkeyCardCol.implicitHeight

    Column {
      id: hotkeyCardCol
      width: parent.width

      Item {
        width: parent.width
        implicitHeight: keybindRow.implicitHeight + Style.space(16)

        Row {
          id: keybindRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(6)

          Ui.TextField {
            id: keybindInput
            width: keybindRow.width - applyKbBtn.implicitWidth - keybindRow.spacing
            text: tab.panel.keybindDraft
            placeholderText: "SUPER + ALT + A"
            foreground: tab.panel.fgColor
            accent: tab.panel.accentColor
            onTextEdited: tab.panel.keybindDraft = text
            onAccepted: tab.panel.applyKeybind()
            Keys.onEscapePressed: tab.panel.close()
          }

          Ui.Button {
            id: applyKbBtn
            foreground: tab.panel.fgColor
            anchors.verticalCenter: parent.verticalCenter
            text: tab.strings.t("settings.apply")
            fontSize: Style.font.bodySmall
            bordered: true
            selected: true
            onClicked: tab.panel.applyKeybind()
          }
        }
      }

      SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

      Item {
        width: parent.width
        implicitHeight: Math.max(Style.space(38), rebindLabel.implicitHeight + Style.space(14))

        SLRoot.PlainText {
          id: rebindLabel
          anchors.left: parent.left
          anchors.right: rebindSwitch.left
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: tab.strings.t("settings.rebindHint")
          color: tab.panel.secondaryInk
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Ui.ToggleSwitch {
          id: rebindSwitch
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          checked: tab.panel.rebindExisting
          foreground: tab.panel.fgColor
          accent: tab.panel.accentColor
          onToggled: tab.panel.rebindExisting = !tab.panel.rebindExisting
        }
      }
    }
  }

  SLUi.SectionLabel {
    text: tab.strings.t("settings.section.appearance").toUpperCase()
    labelColor: tab.panel.mutedInk
    uiFont: tab.panel.uiFont
  }

  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: Style.space(42)

    SLRoot.PlainText {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: tab.strings.t("settings.section.appearance")
      color: tab.panel.fgColor
      font.family: tab.panel.uiFont
      font.pixelSize: Style.font.bodySmall
    }

    Row {
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Repeater {
        model: [
          { id: "system", label: tab.strings.t("settings.theme.system") },
          { id: "dark",   label: tab.strings.t("settings.theme.dark") },
          { id: "light",  label: tab.strings.t("settings.theme.light") }
        ]
        delegate: SLUi.PillOption {
          required property var modelData
          label: modelData.label
          fgColor: tab.panel.fgColor
          accentColor: tab.panel.accentColor
          cornerRadius: tab.panel.cornerRadius
          uiFont: tab.panel.uiFont
          active: tab.panel.cfgVal("theme", "system") === modelData.id
          onClicked: tab.panel.patchConfig({ theme: modelData.id })
        }
      }
    }
  }

  SLUi.SectionLabel {
    text: tab.strings.t("settings.section.capture").toUpperCase()
    labelColor: tab.panel.mutedInk
    uiFont: tab.panel.uiFont
  }

  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: captureCardCol.implicitHeight

    Column {
      id: captureCardCol
      width: parent.width

      Item {
        width: parent.width
        implicitHeight: Style.space(42)

        SLRoot.PlainText {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: tab.strings.t("settings.section.capture")
          color: tab.panel.fgColor
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          SLUi.PillOption {
            icon: "󰒅"
            label: tab.strings.t("mode.lasso")
            fgColor: tab.panel.fgColor
            accentColor: tab.panel.accentColor
            cornerRadius: tab.panel.cornerRadius
            uiFont: tab.panel.uiFont
            active: tab.panel.cfgVal("defaultMode", "lasso") === "lasso"
            onClicked: tab.panel.patchConfig({ defaultMode: "lasso" })
          }

          SLUi.PillOption {
            icon: "󰒉"
            label: tab.strings.t("mode.box")
            fgColor: tab.panel.fgColor
            accentColor: tab.panel.accentColor
            cornerRadius: tab.panel.cornerRadius
            uiFont: tab.panel.uiFont
            active: tab.panel.cfgVal("defaultMode", "lasso") === "box"
            onClicked: tab.panel.patchConfig({ defaultMode: "box" })
          }

          SLUi.PillOption {
            icon: "󰗧"
            label: tab.strings.t("mode.text")
            fgColor: tab.panel.fgColor
            accentColor: tab.panel.accentColor
            cornerRadius: tab.panel.cornerRadius
            uiFont: tab.panel.uiFont
            active: tab.panel.cfgVal("defaultMode", "lasso") === "text"
            onClicked: tab.panel.patchConfig({ defaultMode: "text" })
          }
        }
      }

      SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

      Item {
        width: parent.width
        implicitHeight: Style.space(42)

        SLRoot.PlainText {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: tab.strings.t("settings.maxImageDim")
          color: tab.panel.fgColor
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          Repeater {
            model: [1280, 1920, 2560, 3840]
            delegate: SLUi.PillOption {
              required property int modelData
              label: String(modelData) + "px"
              fontSize: Style.font.caption
              fgColor: tab.panel.fgColor
              accentColor: tab.panel.accentColor
              cornerRadius: tab.panel.cornerRadius
              uiFont: tab.panel.uiFont
              active: Number(tab.panel.cfgVal("maxImageDim", 1920)) === modelData
              onClicked: tab.panel.patchConfig({ maxImageDim: modelData })
            }
          }
        }
      }

      SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

      Item {
        width: parent.width
        implicitHeight: Style.space(38)

        SLRoot.PlainText {
          anchors.left: parent.left
          anchors.right: autoUpdateSwitch.left
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: tab.strings.t("settings.autoCheckUpdates")
          color: tab.panel.secondaryInk
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Ui.ToggleSwitch {
          id: autoUpdateSwitch
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          checked: tab.panel.cfgVal("autoCheckUpdates", true) !== false
          foreground: tab.panel.fgColor
          accent: tab.panel.accentColor
          onToggled: tab.panel.patchConfig({
            autoCheckUpdates: !(tab.panel.cfgVal("autoCheckUpdates", true) !== false)
          })
        }
      }
    }
  }
}
