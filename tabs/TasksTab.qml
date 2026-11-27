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
  readonly property bool taskRoutingOn: !!(tab.panel.config && tab.panel.config.taskRouting && tab.panel.config.taskRouting.enabled)

  SLUi.SectionLabel {
    text: "PER-TASK ROUTING"
    labelColor: tab.panel.mutedInk
    uiFont: tab.panel.uiFont
  }

  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: routingCardCol.implicitHeight

    Column {
      id: routingCardCol
      width: parent.width

      Item {
        width: parent.width
        implicitHeight: Style.space(40)

        SLRoot.PlainText {
          id: routingLabel
          anchors.left: parent.left
          anchors.right: routingSwitch.left
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: tab.strings.t("settings.enableTaskRouting")
          color: tab.panel.fgColor
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Ui.ToggleSwitch {
          id: routingSwitch
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          checked: tab.taskRoutingOn
          foreground: tab.panel.fgColor
          accent: tab.panel.accentColor
          onToggled: tab.panel.patchConfig({
            taskRouting: { enabled: !tab.taskRoutingOn }
          })
        }
      }

      Repeater {
        model: [
          { key: "general",   label: tab.strings.t("settings.task.general") },
          { key: "vision",    label: tab.strings.t("settings.task.vision") },
          { key: "text",      label: tab.strings.t("settings.task.text") },
          { key: "translate", label: tab.strings.t("settings.task.translate") }
        ]
        delegate: Column {
          id: taskRowDelegate
          required property var modelData
          width: routingCardCol.width
          opacity: tab.taskRoutingOn ? 1.0 : 0.42
          enabled: tab.taskRoutingOn

          SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

          Column {
            width: parent.width - Style.space(20)
            x: Style.space(10)
            topPadding: Style.space(8)
            bottomPadding: Style.space(8)
            spacing: Style.space(5)

            SLRoot.PlainText {
              text: taskRowDelegate.modelData.label
              color: tab.panel.secondaryInk
              font.family: tab.panel.uiFont
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Row {
              id: taskPickRow
              width: parent.width
              spacing: Style.space(6)

              Ui.Dropdown {
                width: (taskPickRow.width - taskPickRow.spacing) * 0.42
                showLabel: false
                value: tab.panel.taskProviderValue(taskRowDelegate.modelData.key)
                options: [
                  { value: "", label: tab.strings.t("settings.useDefault") },
                  { value: "auto", label: "Auto" },
                  { value: "gemini", label: "Gemini" },
                  { value: "anthropic", label: "Claude" },
                  { value: "openai", label: "OpenAI" },
                  { value: "ollama", label: "Ollama" },
                  { value: "agent", label: "CLI Agent" }
                ]
                foreground: tab.panel.fgColor
                background: tab.panel.bgColor
                accent: tab.panel.accentColor
                onChanged: function(nextProv) {
                  tab.panel.saveTaskRouting(taskRowDelegate.modelData.key, { provider: nextProv, model: "" })
                }
              }

              Ui.Dropdown {
                width: (taskPickRow.width - taskPickRow.spacing) * 0.58
                showLabel: false
                value: tab.panel.taskModelValue(taskRowDelegate.modelData.key)
                options: tab.panel.taskModelOptions(taskRowDelegate.modelData.key)
                foreground: tab.panel.fgColor
                background: tab.panel.bgColor
                accent: tab.panel.accentColor
                onChanged: function(nextMod) {
                  tab.panel.saveTaskRouting(taskRowDelegate.modelData.key, { model: nextMod })
                }
              }
            }
          }
        }
      }
    }
  }

  SLUi.SectionLabel {
    text: tab.strings.t("settings.task.handoff").toUpperCase()
    labelColor: tab.panel.mutedInk
    uiFont: tab.panel.uiFont
  }

  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: handoffCardCol.implicitHeight + Style.space(16)

    Column {
      id: handoffCardCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(8)
      spacing: Style.space(5)

      Ui.Dropdown {
        width: parent.width
        showLabel: false
        value: String((tab.panel.config && tab.panel.config.taskRouting && tab.panel.config.taskRouting.handoffAgent) || "default")
        options: [
          { value: "default", label: tab.strings.t("settings.handoffDefault") },
          { value: "claude", label: "claude" },
          { value: "codex", label: "codex" },
          { value: "agy", label: "agy" },
          { value: "opencode", label: "opencode" },
          { value: "grok", label: "grok" },
          { value: "gemini", label: "gemini" }
        ]
        foreground: tab.panel.fgColor
        background: tab.panel.bgColor
        accent: tab.panel.accentColor
        onChanged: function(nextCli) {
          tab.panel.patchConfig({ taskRouting: { handoffAgent: nextCli } })
        }
      }
    }
  }
}
