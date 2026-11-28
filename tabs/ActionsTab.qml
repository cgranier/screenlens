import QtQuick
import qs.Commons
import qs.Ui as Ui
import ".." as SLRoot
import "../ScreenLensLogic.js" as Logic
import "../ui" as SLUi

Column {
  id: tab

  required property var panel
  required property var strings

  readonly property var currentChips: Logic.resolveQuickChips(tab.panel.config, {
    explain: tab.strings.t("chip.explain"),
    summarize: tab.strings.t("chip.summarize"),
    translate: tab.strings.t("chip.translate"),
    extract: tab.strings.t("chip.extractText")
  })
  readonly property var iconChoices: ["󰋗", "󰦨", "󰗊", "󰗧", "󰄬", "󰑚", "󰅴", "󰌵", "󰘦", "󰓫", "󰃤", "󰓎"]

  spacing: Style.space(10)

  // Header + Reset Defaults
  Item {
    width: parent.width
    implicitHeight: Math.max(slotSecLbl.implicitHeight, resetBtn.implicitHeight)

    SLUi.SectionLabel {
      id: slotSecLbl
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: tab.strings.t("settings.section.quickChips").toUpperCase()
      labelColor: tab.panel.mutedInk
      uiFont: tab.panel.uiFont
    }

    Ui.Button {
      id: resetBtn
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      foreground: tab.panel.mutedInk
      text: tab.strings.t("settings.actionsReset")
      iconText: "󰑐"
      fontSize: Style.font.caption
      onClicked: tab.panel.resetQuickChips()
    }
  }

  // 4-slot selector (Alt+1..4)
  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: slotsFlow.implicitHeight + Style.space(16)

    Flow {
      id: slotsFlow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(6)

      Repeater {
        model: tab.currentChips
        delegate: SLUi.PillOption {
          required property var modelData
          required property int index
          icon: modelData.icon
          label: modelData.label + " (" + modelData.key + ")"
          fontSize: Style.font.caption
          fgColor: tab.panel.fgColor
          accentColor: tab.panel.accentColor
          cornerRadius: tab.panel.cornerRadius
          uiFont: tab.panel.uiFont
          active: tab.panel.selectedChipIndex === index
          onClicked: tab.panel.selectQuickChipSlot(index)
        }
      }
    }
  }

  // Selected slot editor card
  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: editorCol.implicitHeight

    Column {
      id: editorCol
      width: parent.width

      // 1-click presets row
      Item {
        width: parent.width
        implicitHeight: presetCol.implicitHeight + Style.space(16)

        Column {
          id: presetCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(6)

          SLRoot.PlainText {
            text: tab.strings.t("settings.actionsPresets").arg("Alt+" + (tab.panel.selectedChipIndex + 1))
            color: tab.panel.secondaryInk
            font.family: tab.panel.uiFont
            font.pixelSize: Style.font.caption
          }

          Flow {
            width: parent.width
            spacing: Style.space(5)

            Repeater {
              model: tab.panel.quickChipPresets
              delegate: SLUi.PillOption {
                required property var modelData
                icon: modelData.icon
                label: modelData.label
                fontSize: Style.font.caption
                fgColor: tab.panel.fgColor
                accentColor: tab.panel.accentColor
                cornerRadius: tab.panel.cornerRadius
                uiFont: tab.panel.uiFont
                active: tab.panel.chipLabelDraft === modelData.label && tab.panel.chipActionDraft === modelData.action
                onClicked: tab.panel.applyQuickChipPreset(modelData)
              }
            }
          }
        }
      }

      SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

      // Label + Icon picker
      Item {
        width: parent.width
        implicitHeight: labelIconCol.implicitHeight + Style.space(16)

        Column {
          id: labelIconCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(6)

          SLRoot.PlainText {
            text: tab.strings.t("settings.actionsLabelField")
            color: tab.panel.secondaryInk
            font.family: tab.panel.uiFont
            font.pixelSize: Style.font.caption
          }

          Ui.TextField {
            width: parent.width
            text: tab.panel.chipLabelDraft
            placeholderText: "Explain"
            foreground: tab.panel.fgColor
            accent: tab.panel.accentColor
            onTextEdited: tab.panel.chipLabelDraft = text
            onAccepted: tab.panel.saveQuickChipSlot()
            Keys.onEscapePressed: tab.panel.close()
          }

          Row {
            spacing: Style.space(4)

            Repeater {
              model: tab.iconChoices
              delegate: Rectangle {
                required property string modelData
                readonly property bool picked: tab.panel.chipIconDraft === modelData
                width: Style.space(26)
                height: Style.space(26)
                radius: Math.min(4, tab.panel.cornerRadius)
                color: picked
                  ? Util.alpha(tab.panel.accentColor, 0.22)
                  : (iconHover.hovered ? tab.panel.hoverFill : tab.panel.restFill)
                border.width: 1
                border.color: picked ? Util.alpha(tab.panel.accentColor, 0.72) : tab.panel.cardBorder

                SLRoot.PlainText {
                  anchors.centerIn: parent
                  text: modelData
                  color: picked ? tab.panel.accentColor : tab.panel.fgColor
                  font.family: tab.panel.uiFont
                  font.pixelSize: Style.font.body
                }

                HoverHandler { id: iconHover; cursorShape: Qt.PointingHandCursor }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: tab.panel.chipIconDraft = modelData
                }
              }
            }
          }
        }
      }

      SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

      // Action type (AI Prompt vs 0 ms Extract Text OCR)
      Item {
        width: parent.width
        implicitHeight: Style.space(40)

        SLRoot.PlainText {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: tab.strings.t("settings.actionsKind")
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
            label: tab.strings.t("settings.actionsKindPrompt")
            fontSize: Style.font.caption
            fgColor: tab.panel.fgColor
            accentColor: tab.panel.accentColor
            cornerRadius: tab.panel.cornerRadius
            uiFont: tab.panel.uiFont
            active: tab.panel.chipActionDraft !== "extract_text"
            onClicked: tab.panel.chipActionDraft = "prompt"
          }

          SLUi.PillOption {
            label: tab.strings.t("settings.actionsKindExtract")
            fontSize: Style.font.caption
            fgColor: tab.panel.fgColor
            accentColor: tab.panel.accentColor
            cornerRadius: tab.panel.cornerRadius
            uiFont: tab.panel.uiFont
            active: tab.panel.chipActionDraft === "extract_text"
            onClicked: tab.panel.chipActionDraft = "extract_text"
          }
        }
      }

      SLUi.CardDivider {
        visible: tab.panel.chipActionDraft !== "extract_text"
        width: parent.width
        dividerColor: tab.panel.rowDivider
      }

      // Task routing category + prompt template (when action is AI Prompt)
      Item {
        visible: tab.panel.chipActionDraft !== "extract_text"
        width: parent.width
        implicitHeight: promptCol.implicitHeight + Style.space(16)

        Column {
          id: promptCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(6)

          SLRoot.PlainText {
            text: tab.strings.t("settings.actionsTaskRoute")
            color: tab.panel.secondaryInk
            font.family: tab.panel.uiFont
            font.pixelSize: Style.font.caption
          }

          Flow {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: [
                { id: "auto",      label: "Auto" },
                { id: "general",   label: "General" },
                { id: "vision",    label: "Vision" },
                { id: "text",      label: "Text" },
                { id: "translate", label: "Translate" }
              ]
              delegate: SLUi.PillOption {
                required property var modelData
                label: modelData.label
                fontSize: Style.font.caption
                fgColor: tab.panel.fgColor
                accentColor: tab.panel.accentColor
                cornerRadius: tab.panel.cornerRadius
                uiFont: tab.panel.uiFont
                active: tab.panel.chipTaskDraft === modelData.id
                onClicked: tab.panel.chipTaskDraft = modelData.id
              }
            }
          }

          SLRoot.PlainText {
            text: tab.strings.t("settings.actionsPromptField")
            color: tab.panel.secondaryInk
            font.family: tab.panel.uiFont
            font.pixelSize: Style.font.caption
          }

          Ui.TextField {
            width: parent.width
            text: tab.panel.chipPromptDraft
            placeholderText: tab.strings.t("settings.actionsPromptPlaceholder")
            foreground: tab.panel.fgColor
            accent: tab.panel.accentColor
            onTextEdited: tab.panel.chipPromptDraft = text
            onAccepted: tab.panel.saveQuickChipSlot()
            Keys.onEscapePressed: tab.panel.close()
          }

          SLRoot.PlainText {
            width: parent.width
            text: tab.strings.t("settings.actionsTemplateHint")
            color: tab.panel.mutedInk
            font.family: tab.panel.uiFont
            font.pixelSize: Math.max(9, Style.font.caption - 1)
            wrapMode: Text.Wrap
          }
        }
      }

      SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

      // Save row
      Item {
        width: parent.width
        implicitHeight: saveSlotBtn.implicitHeight + Style.space(14)

        SLRoot.PlainText {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: "Alt+" + (tab.panel.selectedChipIndex + 1) + " · " + (tab.panel.chipIconDraft || "") + " " + (tab.panel.chipLabelDraft || "")
          color: tab.panel.mutedInk
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.caption
        }

        Ui.Button {
          id: saveSlotBtn
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          foreground: tab.panel.fgColor
          text: tab.strings.t("settings.save")
          fontSize: Style.font.bodySmall
          bordered: true
          selected: true
          onClicked: tab.panel.saveQuickChipSlot()
        }
      }
    }
  }

  // Smart context actions toggle
  SLUi.SectionLabel {
    text: tab.strings.t("settings.section.smartActions").toUpperCase()
    labelColor: tab.panel.mutedInk
    uiFont: tab.panel.uiFont
  }

  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: Math.max(Style.space(40), smartLbl.implicitHeight + Style.space(14))

    SLRoot.PlainText {
      id: smartLbl
      anchors.left: parent.left
      anchors.right: smartSwitch.left
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: tab.strings.t("settings.smartActionsToggle")
      color: tab.panel.secondaryInk
      font.family: tab.panel.uiFont
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }

    Ui.ToggleSwitch {
      id: smartSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      checked: tab.panel.cfgVal("smartActionsEnabled", true) !== false
      foreground: tab.panel.fgColor
      accent: tab.panel.accentColor
      onToggled: tab.panel.patchConfig({
        smartActionsEnabled: !(tab.panel.cfgVal("smartActionsEnabled", true) !== false)
      })
    }
  }
}
