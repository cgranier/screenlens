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
    text: tab.strings.t("settings.defaultProvider").toUpperCase()
    labelColor: tab.panel.mutedInk
    uiFont: tab.panel.uiFont
  }

  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: tab.panel.cardBorder
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: defaultProvFlow.implicitHeight + Style.space(16)

    Flow {
      id: defaultProvFlow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(8)
      spacing: Style.space(5)

      Repeater {
        model: [
          { id: "auto",      label: "Auto" },
          { id: "gemini",    label: "Gemini" },
          { id: "anthropic", label: "Claude" },
          { id: "openai",    label: "OpenAI" },
          { id: "ollama",    label: "Ollama" },
          { id: "agent",     label: "CLI Agent" }
        ]
        delegate: SLUi.PillOption {
          required property var modelData
          label: modelData.label
          fgColor: tab.panel.fgColor
          accentColor: tab.panel.accentColor
          cornerRadius: tab.panel.cornerRadius
          uiFont: tab.panel.uiFont
          active: tab.panel.cfgVal("defaultProvider", "auto") === modelData.id
          onClicked: tab.panel.patchConfig({ defaultProvider: modelData.id })
        }
      }
    }
  }

  SLUi.SectionLabel {
    text: tab.strings.t("settings.configuredProviders").toUpperCase()
    labelColor: tab.panel.mutedInk
    uiFont: tab.panel.uiFont
  }

  // Provider selector strip with live configured status dots
  Flow {
    width: parent.width
    spacing: Style.space(5)

    Repeater {
      model: [
        { id: "gemini",    label: "Gemini" },
        { id: "anthropic", label: "Claude" },
        { id: "openai",    label: "OpenAI" },
        { id: "ollama",    label: "Ollama" },
        { id: "agent",     label: "CLI Agent" }
      ]
      delegate: SLUi.PillOption {
        required property var modelData
        label: modelData.label
        fontSize: Style.font.caption
        fgColor: tab.panel.fgColor
        accentColor: tab.panel.accentColor
        cornerRadius: tab.panel.cornerRadius
        uiFont: tab.panel.uiFont
        showDot: true
        dotReady: tab.panel.providerReady(modelData.id)
        active: tab.panel.selectedProvider === modelData.id
        onClicked: tab.panel.selectProvider(modelData.id)
      }
    }
  }

  // Active provider detail editor card
  SLUi.SectionCard {
    width: parent.width
    fill: tab.panel.cardFill
    stroke: Util.alpha(tab.panel.accentColor, 0.32)
    cornerRadius: tab.panel.cornerRadius
    implicitHeight: providerEditorCol.implicitHeight + Style.space(20)

    Column {
      id: providerEditorCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      // Provider title + status + Get key + Test
      Item {
        width: parent.width
        implicitHeight: Math.max(provTitleCol.implicitHeight, provActionsRow.implicitHeight)

        Column {
          id: provTitleCol
          anchors.left: parent.left
          anchors.right: provActionsRow.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          SLRoot.PlainText {
            text: String(tab.panel.currentProviderMeta().name || tab.panel.selectedProvider)
            color: tab.panel.fgColor
            font.family: tab.panel.uiFont
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Row {
            spacing: Style.space(5)

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(6)
              height: Style.space(6)
              radius: width / 2
              color: tab.panel.providerReady(tab.panel.selectedProvider) ? tab.panel.accentColor : "transparent"
              border.width: tab.panel.providerReady(tab.panel.selectedProvider) ? 0 : 1
              border.color: tab.panel.mutedInk
            }

            SLRoot.PlainText {
              anchors.verticalCenter: parent.verticalCenter
              text: tab.panel.providerStatusBadge(tab.panel.selectedProvider)
              color: tab.panel.providerReady(tab.panel.selectedProvider) ? tab.panel.accentColor : tab.panel.mutedInk
              font.family: tab.panel.uiFont
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Row {
          id: provActionsRow
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(5)

          Ui.Button {
            foreground: tab.panel.fgColor
            visible: String(tab.panel.currentProviderMeta().keyUrl || "").length > 0
            text: tab.strings.t("settings.getApiKey")
            fontSize: Style.font.caption
            bordered: true
            onClicked: tab.panel.openKeyConsole(tab.panel.selectedProvider)
          }

          Ui.Button {
            foreground: tab.panel.fgColor
            text: tab.panel.testingProvider ? tab.strings.t("settings.testing") : tab.strings.t("settings.testConnection")
            iconText: "󰙨"
            iconSpinning: tab.panel.testingProvider
            fontSize: Style.font.caption
            bordered: true
            selected: true
            onClicked: tab.panel.testSelectedProvider()
          }
        }
      }

      // Inline test result pill
      Rectangle {
        visible: tab.panel.providerTestText.length > 0
        width: parent.width
        radius: Math.min(3, tab.panel.cornerRadius)
        color: tab.panel.providerTestOk ? Util.alpha(tab.panel.accentColor, 0.12) : Util.alpha(tab.panel.urgentColor, 0.14)
        border.width: 1
        border.color: tab.panel.providerTestOk ? Util.alpha(tab.panel.accentColor, 0.36) : Util.alpha(tab.panel.urgentColor, 0.45)
        implicitHeight: provTestLabel.implicitHeight + Style.space(10)

        SLRoot.PlainText {
          id: provTestLabel
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          text: tab.panel.providerTestText
          color: tab.panel.providerTestOk ? tab.panel.accentColor : tab.panel.urgentColor
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.caption
          font.bold: true
          wrapMode: Text.Wrap
        }
      }

      SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

      // Model dropdown + refresh button
      Row {
        id: modelRow
        width: parent.width
        spacing: Style.space(6)

        Ui.Dropdown {
          width: modelRow.width - refreshModelsBtn.implicitWidth - modelRow.spacing
          label: tab.strings.t("settings.modelLabel")
          value: String(tab.panel.currentProviderCfg().model || tab.panel.currentProviderMeta().defaultModel || "")
          options: tab.panel.currentProviderModels()
          foreground: tab.panel.fgColor
          background: tab.panel.bgColor
          accent: tab.panel.accentColor
          onChanged: function(nextModel) {
            tab.panel.saveProviderField(tab.panel.selectedProvider, { model: nextModel })
          }
        }

        Ui.Button {
          id: refreshModelsBtn
          foreground: tab.panel.fgColor
          anchors.bottom: parent.bottom
          iconText: "󰑐"
          iconSpinning: tab.panel.refreshingModels
          bordered: true
          tooltipText: tab.strings.t("settings.refreshModels")
          onClicked: tab.panel.refreshModelsFor(tab.panel.selectedProvider)
        }
      }

      // Custom model ID override
      Row {
        id: customModelRow
        width: parent.width
        spacing: Style.space(6)

        Ui.TextField {
          width: customModelRow.width - saveModelBtn.implicitWidth - customModelRow.spacing
          text: tab.panel.customModelDraft
          placeholderText: tab.strings.t("settings.customModelPlaceholder")
          foreground: tab.panel.fgColor
          accent: tab.panel.accentColor
          onTextEdited: tab.panel.customModelDraft = text
          onAccepted: {
            var m = tab.panel.customModelDraft.trim()
            if (m) {
              tab.panel.saveProviderField(tab.panel.selectedProvider, { model: m })
              tab.panel.customModelDraft = ""
            }
          }
          Keys.onEscapePressed: tab.panel.close()
        }

        Ui.Button {
          id: saveModelBtn
          foreground: tab.panel.fgColor
          anchors.verticalCenter: parent.verticalCenter
          text: tab.strings.t("settings.save")
          fontSize: Style.font.caption
          bordered: true
          onClicked: {
            var m = tab.panel.customModelDraft.trim()
            if (m) {
              tab.panel.saveProviderField(tab.panel.selectedProvider, { model: m })
              tab.panel.customModelDraft = ""
            }
          }
        }
      }

      // Masked API key editor (Gemini / Anthropic / OpenAI)
      Column {
        visible: tab.panel.currentProviderMeta().requiresKey === true
        width: parent.width
        spacing: Style.space(5)

        SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

        SLRoot.PlainText {
          text: tab.strings.t("settings.apiKeyLabel")
          color: tab.panel.secondaryInk
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Row {
          id: apiKeyRow
          width: parent.width
          spacing: Style.space(6)

          Ui.TextField {
            width: apiKeyRow.width - saveKeyBtn.implicitWidth - (clearKeyBtn.visible ? clearKeyBtn.implicitWidth + apiKeyRow.spacing : 0) - apiKeyRow.spacing
            password: true
            text: tab.panel.apiKeyDraft
            placeholderText: tab.panel.currentProviderCfg().hasKey
              ? tab.strings.t("settings.apiKeySavedPlaceholder").arg(String(tab.panel.currentProviderCfg().maskedKey || "••••"))
              : tab.strings.t("settings.apiKeyPlaceholder")
            foreground: tab.panel.fgColor
            accent: tab.panel.accentColor
            onTextEdited: tab.panel.apiKeyDraft = text
            onAccepted: {
              var k = tab.panel.apiKeyDraft.trim()
              if (k) {
                tab.panel.saveProviderField(tab.panel.selectedProvider, { apiKey: k })
                tab.panel.apiKeyDraft = ""
              }
            }
            Keys.onEscapePressed: tab.panel.close()
          }

          Ui.Button {
            id: saveKeyBtn
            foreground: tab.panel.fgColor
            anchors.verticalCenter: parent.verticalCenter
            text: tab.strings.t("settings.save")
            fontSize: Style.font.caption
            bordered: true
            selected: tab.panel.apiKeyDraft.trim().length > 0
            onClicked: {
              var k = tab.panel.apiKeyDraft.trim()
              if (k) {
                tab.panel.saveProviderField(tab.panel.selectedProvider, { apiKey: k })
                tab.panel.apiKeyDraft = ""
              }
            }
          }

          Ui.Button {
            id: clearKeyBtn
            foreground: tab.panel.fgColor
            visible: tab.panel.currentProviderCfg().hasKey === true
            anchors.verticalCenter: parent.verticalCenter
            text: tab.strings.t("settings.clear")
            fontSize: Style.font.caption
            bordered: true
            onClicked: {
              tab.panel.apiKeyDraft = ""
              tab.panel.saveProviderField(tab.panel.selectedProvider, { apiKey: "" })
            }
          }
        }
      }

      // Ollama server URL editor
      Column {
        visible: tab.panel.selectedProvider === "ollama"
        width: parent.width
        spacing: Style.space(5)

        SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

        SLRoot.PlainText {
          text: tab.strings.t("settings.ollamaHostLabel")
          color: tab.panel.secondaryInk
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Row {
          id: ollamaRow
          width: parent.width
          spacing: Style.space(6)

          Ui.TextField {
            width: ollamaRow.width - saveOllamaBtn.implicitWidth - ollamaRow.spacing
            text: tab.panel.ollamaHostDraft
            placeholderText: "http://127.0.0.1:11434"
            foreground: tab.panel.fgColor
            accent: tab.panel.accentColor
            onTextEdited: tab.panel.ollamaHostDraft = text
            onAccepted: tab.panel.saveProviderField("ollama", { host: tab.panel.ollamaHostDraft.trim() })
            Keys.onEscapePressed: tab.panel.close()
          }

          Ui.Button {
            id: saveOllamaBtn
            foreground: tab.panel.fgColor
            anchors.verticalCenter: parent.verticalCenter
            text: tab.strings.t("settings.save")
            fontSize: Style.font.caption
            bordered: true
            onClicked: tab.panel.saveProviderField("ollama", { host: tab.panel.ollamaHostDraft.trim() })
          }
        }
      }

      // Omarchy CLI agent selector
      Column {
        visible: tab.panel.selectedProvider === "agent"
        width: parent.width
        spacing: Style.space(5)

        SLUi.CardDivider { width: parent.width; dividerColor: tab.panel.rowDivider }

        SLRoot.PlainText {
          text: tab.strings.t("settings.cliAgentLabel")
          color: tab.panel.secondaryInk
          font.family: tab.panel.uiFont
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Flow {
          width: parent.width
          spacing: Style.space(5)

          Repeater {
            model: Array.isArray(tab.panel.currentProviderMeta().clis)
              ? tab.panel.currentProviderMeta().clis
              : ["default", "claude", "codex", "agy", "opencode", "grok", "gemini"]
            delegate: SLUi.PillOption {
              required property string modelData
              label: modelData
              fontSize: Style.font.caption
              fgColor: tab.panel.fgColor
              accentColor: tab.panel.accentColor
              cornerRadius: tab.panel.cornerRadius
              uiFont: tab.panel.uiFont
              active: String(tab.panel.currentProviderCfg().cli || "default") === modelData
              onClicked: tab.panel.selectAgentCli(modelData)
            }
          }
        }
      }
    }
  }
}
