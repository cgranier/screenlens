import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

// Reel-inspired tabbed Settings panel for ScreenLens.
// Left-clicking the bar icon opens Settings; right-clicking launches the
// fullscreen ScreenLens overlay immediately. Also reachable from the overlay's
// top-bar gear button via `omarchy-shell screenlens-settings open`.
Ui.Panel {
  id: root
  moduleName: "carlos.screenlens"
  ipcTarget: "screenlens-settings"
  manageIpc: false

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property color bgColor: Commons.Color.popups.background
  readonly property color fgColor: Commons.Color.popups.text
  readonly property color accentColor: Commons.Color.accent
  readonly property color urgentColor: Commons.Color.urgent
  readonly property color borderColor: Commons.Color.popups.border
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string uiFont: Style.font.family

  property string activeTab: "general" // "general" | "providers" | "tasks" | "language"
  readonly property var tabIds: ["general", "providers", "tasks", "language"]

  // Live config state loaded from 0600 ~/.config/omarchy/screenlens.json
  property var config: ({})
  property var catalog: ({})
  property string keybindDraft: "SUPER + ALT + A"
  property bool rebindExisting: false
  property bool busy: false
  property string statusText: ""
  property bool statusError: false
  property string pendingPatchJson: ""

  // Providers tab state
  property string selectedProvider: "gemini"
  property var discoveredModels: ({}) // { providerId: [modelIds...] }
  property bool refreshingModels: false
  property bool testingProvider: false
  property string providerTestText: ""
  property bool providerTestOk: false
  property string apiKeyDraft: ""
  property string customModelDraft: ""
  property string ollamaHostDraft: "http://127.0.0.1:11434"

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  ShellIpc {
    enabled: true
    target: "screenlens-settings"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function openTab(tabName: string): void {
      if (root.tabIds.indexOf(tabName) !== -1) root.activeTab = tabName
      root.open()
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.statusText = ""
      root.statusError = false
      root.loadState()
    }
  }

  function cycleTab(delta) {
    var idx = root.tabIds.indexOf(root.activeTab)
    if (idx < 0) idx = 0
    root.activeTab = root.tabIds[(idx + delta + root.tabIds.length) % root.tabIds.length]
  }

  function launchCapture() {
    root.close()
    Util.execArgv(["omarchy-shell", "shell", "summon", "carlos.screenlens", "{}"])
  }

  function loadState() {
    loadConfigProc.running = false
    loadConfigProc.running = true
    if (Object.keys(root.catalog).length === 0) {
      loadCatalogProc.running = false
      loadCatalogProc.running = true
    }
  }

  function setStatus(msg, isErr) {
    root.statusText = String(msg || "")
    root.statusError = isErr === true
    statusClearTimer.restart()
  }

  function patchConfig(patchObj) {
    root.busy = true
    root.pendingPatchJson = JSON.stringify(patchObj)
    patchProc.running = false
    patchProc.running = true
  }

  function selectProvider(provId) {
    root.selectedProvider = provId
    root.apiKeyDraft = ""
    root.customModelDraft = ""
    root.providerTestText = ""
    root.providerTestOk = false
    var provs = (root.config && root.config.providers) ? root.config.providers : ({})
    var p = provs[provId] || ({})
    if (provId === "ollama") {
      root.ollamaHostDraft = String(p.host || "http://127.0.0.1:11434")
    }
  }

  function currentProviderCfg() {
    var provs = (root.config && root.config.providers) ? root.config.providers : ({})
    return provs[root.selectedProvider] || ({})
  }

  function currentProviderMeta() {
    return (root.catalog && root.catalog[root.selectedProvider]) ? root.catalog[root.selectedProvider] : ({})
  }

  function currentProviderModels() {
    var live = root.discoveredModels[root.selectedProvider]
    var base = Array.isArray(live) && live.length > 0
      ? live.slice()
      : (Array.isArray(currentProviderMeta().models) ? currentProviderMeta().models.slice() : [])
    var active = String(currentProviderCfg().model || "")
    if (active && base.indexOf(active) === -1) base.unshift(active)
    return base
  }

  function providerStatusBadge(provId) {
    var provs = (root.config && root.config.providers) ? root.config.providers : ({})
    var p = provs[provId] || ({})
    if (provId === "ollama") return String(p.host || "http://127.0.0.1:11434")
    if (provId === "agent") return String(p.cli || "default")
    if (p.hasKey) return strings.t("settings.keySet") + (p.maskedKey ? (" " + p.maskedKey) : "")
    if (p.hasEnvKey) return strings.t("settings.keyEnv") + (p.maskedKey ? (" " + p.maskedKey) : "")
    return strings.t("settings.keyUnset")
  }

  function saveProviderField(provId, fields) {
    var patch = { providers: {} }
    patch.providers[provId] = fields
    root.patchConfig(patch)
  }

  function refreshModelsFor(provId) {
    if (root.refreshingModels) return
    root.refreshingModels = true
    listModelsProc.command = ["/usr/bin/python3", root.pluginDir + "/scripts/providers.py", "list-models", provId]
    listModelsProc.running = false
    listModelsProc.running = true
  }

  function testSelectedProvider() {
    if (root.testingProvider) return
    root.testingProvider = true
    root.providerTestText = strings.t("settings.testing")
    root.providerTestOk = false
    testProvProc.command = ["/usr/bin/python3", root.pluginDir + "/scripts/providers.py", "test", root.selectedProvider]
    testProvProc.running = false
    testProvProc.running = true
  }

  function openKeyConsole(provId) {
    Util.execArgv(["/usr/bin/python3", root.pluginDir + "/scripts/providers.py", "open-key-url", provId])
  }

  function applyKeybind() {
    var chord = String(root.keybindDraft || "").trim()
    if (!chord) return
    root.busy = true
    var cmd = [
      "/usr/bin/python3",
      root.pluginDir + "/scripts/config.py",
      "set-keybind",
      chord
    ]
    if (root.rebindExisting) cmd.push("--rebind")
    keybindProc.command = cmd
    keybindProc.running = false
    keybindProc.running = true
  }

  function cfgVal(key, fallback) {
    if (!root.config || root.config[key] === undefined || root.config[key] === null) return fallback
    return root.config[key]
  }

  function providerSummary(provId) {
    var provs = (root.config && root.config.providers) ? root.config.providers : ({})
    var p = provs[provId] || ({})
    if (provId === "ollama") {
      return (p.model || "llama3.2-vision") + " · " + (p.host || "http://127.0.0.1:11434")
    }
    if (provId === "agent") {
      return (p.cli || "default") + " · " + (p.model || "haiku")
    }
    var keyBadge = p.hasKey ? (strings.t("settings.keySet") + " " + (p.maskedKey || "")) : strings.t("settings.keyUnset")
    return (p.model || "") + " · " + keyBadge
  }

  function taskSummary(taskKey) {
    var routing = (root.config && root.config.taskRouting) ? root.config.taskRouting : ({})
    if (taskKey === "handoffAgent") {
      return String(routing.handoffAgent || "default")
    }
    var entry = routing[taskKey] || ({})
    var prov = String(entry.provider || "")
    var mod = String(entry.model || "")
    if (!prov && !mod) return strings.t("settings.useDefault")
    return (prov || "auto") + (mod ? (" · " + mod) : "")
  }

  Timer {
    id: statusClearTimer
    interval: 3500
    repeat: false
    onTriggered: {
      if (!root.statusError) root.statusText = ""
    }
  }

  Process {
    id: loadConfigProc
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/config.py", "get", "--redact"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.config) {
          root.config = res.config
          root.keybindDraft = String(res.config.keybind || "SUPER + ALT + A")
          var ol = (res.config.providers && res.config.providers.ollama) ? res.config.providers.ollama : ({})
          root.ollamaHostDraft = String(ol.host || "http://127.0.0.1:11434")
        }
      }
    }
  }

  Process {
    id: loadCatalogProc
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/config.py", "catalog"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.providers) {
          root.catalog = res.providers
        }
      }
    }
  }

  Process {
    id: patchProc
    stdinEnabled: true
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/config.py", "patch"]
    onStarted: patchProc.write(root.pendingPatchJson + "\n")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.config) {
          root.config = res.config
          root.setStatus(strings.t("settings.saved"), false)
        } else {
          root.setStatus((res && res.error) ? res.error : strings.t("settings.saveFailed"), true)
        }
      }
    }
  }

  Process {
    id: listModelsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.refreshingModels = false
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.provider && Array.isArray(res.models)) {
          var next = Object.assign({}, root.discoveredModels)
          next[res.provider] = res.models
          root.discoveredModels = next
          root.setStatus(
            res.note ? res.note : strings.t("settings.modelsRefreshed").arg(String(res.models.length)),
            false
          )
        } else {
          root.setStatus((res && res.error) ? res.error : "Could not refresh models", true)
        }
      }
    }
  }

  Process {
    id: testProvProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.testingProvider = false
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok) {
          root.providerTestOk = true
          root.providerTestText = strings.t("settings.testOk")
            .arg(String(res.detail || "Connected"))
            .arg(Commons.I18n.formatNumber(Number(res.latencyMs || 0)))
        } else {
          root.providerTestOk = false
          root.providerTestText = (res && res.error) ? String(res.error) : "Connection failed"
        }
      }
    }
  }

  Process {
    id: keybindProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.keybind) {
          root.keybindDraft = res.keybind
          root.loadState()
          root.setStatus(strings.t("settings.keybindApplied").arg(res.keybind), false)
        } else {
          root.setStatus((res && res.error) ? res.error : strings.t("settings.keybindFailed"), true)
        }
      }
    }
  }

  // Top-bar widget icon: left-click toggles Settings, right-click captures screen.
  Ui.BarIconButton {
    id: barButton
    bar: root.bar
    text: "󰍉"
    active: root.opened
    foreground: root.barForeground
    activeColor: root.accentColor
    tooltipText: strings.t("settings.barTooltip")
    onPressed: function(button) {
      if (button === Qt.RightButton) root.launchCapture()
      else root.toggle()
    }
  }

  Ui.KeyboardPanel {
    id: panelWindow
    anchorItem: barButton
    bar: root.bar
    owner: root
    open: root.opened
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing
    contentWidth: Style.space(520)
    contentHeight: Math.min(Style.space(620), Math.max(Style.space(320), panelColumn.implicitHeight + Style.spacing.popupPadding * 2))
    focusTarget: panelKeyCatcher

    Item {
      id: panelKeyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          root.cycleTab(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Backtab) {
          root.cycleTab(-1)
          event.accepted = true
        }
      }

      Column {
        id: panelColumn
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.spacing.sm

        // Header row
        Item {
          width: parent.width
          implicitHeight: Math.max(headerLeft.implicitHeight, headerRight.implicitHeight)

          Row {
            id: headerLeft
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            PlainText {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍉"
              color: root.accentColor
              font.family: root.uiFont
              font.pixelSize: Style.font.icon
            }

            PlainText {
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("settings.title")
              color: root.fgColor
              font.family: root.uiFont
              font.pixelSize: Style.font.title
              font.bold: true
            }
          }

          Row {
            id: headerRight
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Ui.Button {
              text: strings.t("settings.captureNow")
              iconText: "󰒅"
              fontSize: Style.font.bodySmall
              selected: true
              onClicked: root.launchCapture()
            }

            Ui.Button {
              iconText: "󰅖"
              tooltipText: strings.t("action.close")
              onClicked: root.close()
            }
          }
        }

        // Reel-style horizontal tab strip
        Row {
          width: parent.width
          spacing: Style.spacing.xs

          Ui.Button {
            text: strings.t("settings.tab.general")
            iconText: "󰒓"
            fontSize: Style.font.bodySmall
            selected: root.activeTab === "general"
            bordered: true
            onClicked: root.activeTab = "general"
          }

          Ui.Button {
            text: strings.t("settings.tab.providers")
            iconText: "󰚩"
            fontSize: Style.font.bodySmall
            selected: root.activeTab === "providers"
            bordered: true
            onClicked: root.activeTab = "providers"
          }

          Ui.Button {
            text: strings.t("settings.tab.tasks")
            iconText: "󰒋"
            fontSize: Style.font.bodySmall
            selected: root.activeTab === "tasks"
            bordered: true
            onClicked: root.activeTab = "tasks"
          }

          Ui.Button {
            text: strings.t("settings.tab.language")
            iconText: "󰗊"
            fontSize: Style.font.bodySmall
            selected: root.activeTab === "language"
            bordered: true
            onClicked: root.activeTab = "language"
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(root.fgColor, 0.14)
        }

        // ============================================================ GENERAL TAB
        Column {
          visible: root.activeTab === "general"
          width: parent.width
          spacing: Style.spacing.sm

          Ui.PanelSectionHeader {
            text: strings.t("settings.section.keybind")
            foreground: root.fgColor
          }

          Row {
            id: keybindRow
            width: parent.width
            spacing: Style.spacing.xs

            Ui.TextField {
              id: keybindInput
              width: keybindRow.width - applyKbBtn.implicitWidth - keybindRow.spacing
              text: root.keybindDraft
              placeholderText: "SUPER + ALT + A"
              foreground: root.fgColor
              accent: root.accentColor
              onTextEdited: root.keybindDraft = text
              onAccepted: root.applyKeybind()
              Keys.onEscapePressed: root.close()
            }

            Ui.Button {
              id: applyKbBtn
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("settings.apply")
              bordered: true
              selected: true
              onClicked: root.applyKeybind()
            }
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(rebindLabel.implicitHeight, rebindSwitch.implicitHeight)

            PlainText {
              id: rebindLabel
              anchors.left: parent.left
              anchors.right: rebindSwitch.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("settings.rebindHint")
              color: Util.alpha(root.fgColor, 0.72)
              font.family: root.uiFont
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Ui.ToggleSwitch {
              id: rebindSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.rebindExisting
              foreground: root.fgColor
              accent: root.accentColor
              onToggled: root.rebindExisting = !root.rebindExisting
            }
          }

          Ui.PanelSectionHeader {
            text: strings.t("settings.section.appearance")
            foreground: root.fgColor
          }

          Row {
            spacing: Style.spacing.xs

            Repeater {
              model: [
                { id: "system", label: strings.t("settings.theme.system") },
                { id: "dark", label: strings.t("settings.theme.dark") },
                { id: "light", label: strings.t("settings.theme.light") }
              ]
              delegate: Ui.Button {
                text: modelData.label
                fontSize: Style.font.bodySmall
                bordered: true
                selected: root.cfgVal("theme", "system") === modelData.id
                onClicked: root.patchConfig({ theme: modelData.id })
              }
            }
          }

          Ui.PanelSectionHeader {
            text: strings.t("settings.section.capture")
            foreground: root.fgColor
          }

          Row {
            spacing: Style.spacing.xs

            Ui.Button {
              text: strings.t("mode.lasso")
              iconText: "󰒅"
              fontSize: Style.font.bodySmall
              bordered: true
              selected: root.cfgVal("defaultMode", "lasso") === "lasso"
              onClicked: root.patchConfig({ defaultMode: "lasso" })
            }

            Ui.Button {
              text: strings.t("mode.text")
              iconText: "󰗧"
              fontSize: Style.font.bodySmall
              bordered: true
              selected: root.cfgVal("defaultMode", "lasso") === "text"
              onClicked: root.patchConfig({ defaultMode: "text" })
            }
          }

          Row {
            spacing: Style.spacing.xs

            PlainText {
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("settings.maxImageDim")
              color: Util.alpha(root.fgColor, 0.78)
              font.family: root.uiFont
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: [1280, 1920, 2560, 3840]
              delegate: Ui.Button {
                text: String(modelData) + "px"
                fontSize: Style.font.caption
                bordered: true
                selected: Number(root.cfgVal("maxImageDim", 1920)) === modelData
                onClicked: root.patchConfig({ maxImageDim: modelData })
              }
            }
          }
        }

        // ============================================================ PROVIDERS TAB
        Column {
          visible: root.activeTab === "providers"
          width: parent.width
          spacing: Style.spacing.sm

          Ui.PanelSectionHeader {
            text: strings.t("settings.defaultProvider")
            foreground: root.fgColor
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: [
                { id: "auto", label: "Auto" },
                { id: "gemini", label: "Gemini" },
                { id: "anthropic", label: "Claude" },
                { id: "openai", label: "OpenAI" },
                { id: "ollama", label: "Ollama" },
                { id: "agent", label: "CLI Agent" }
              ]
              delegate: Ui.Button {
                text: modelData.label
                fontSize: Style.font.bodySmall
                bordered: true
                selected: root.cfgVal("defaultProvider", "auto") === modelData.id
                onClicked: root.patchConfig({ defaultProvider: modelData.id })
              }
            }
          }

          Ui.PanelSectionHeader {
            text: strings.t("settings.configuredProviders")
            foreground: root.fgColor
          }

          // Provider selector pills
          Flow {
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: [
                { id: "gemini", label: "Gemini" },
                { id: "anthropic", label: "Claude" },
                { id: "openai", label: "OpenAI" },
                { id: "ollama", label: "Ollama" },
                { id: "agent", label: "CLI Agent" }
              ]
              delegate: Ui.Button {
                text: modelData.label
                fontSize: Style.font.caption
                bordered: true
                selected: root.selectedProvider === modelData.id
                onClicked: root.selectProvider(modelData.id)
              }
            }
          }

          // Active provider detail editor card
          Rectangle {
            width: parent.width
            radius: Math.min(4, root.cornerRadius)
            color: Util.alpha(root.fgColor, 0.05)
            border.width: 1
            border.color: Util.alpha(root.accentColor, 0.35)
            implicitHeight: providerEditorCol.implicitHeight + Style.spacing.md * 2

            Column {
              id: providerEditorCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.spacing.md
              spacing: Style.spacing.sm

              // Provider title + status badge + Get key + Test
              Item {
                width: parent.width
                implicitHeight: Math.max(provTitleCol.implicitHeight, provActionsRow.implicitHeight)

                Column {
                  id: provTitleCol
                  anchors.left: parent.left
                  anchors.right: provActionsRow.left
                  anchors.rightMargin: Style.spacing.xs
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  PlainText {
                    text: String(root.currentProviderMeta().name || root.selectedProvider)
                    color: root.fgColor
                    font.family: root.uiFont
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  PlainText {
                    text: root.providerStatusBadge(root.selectedProvider)
                    color: (root.currentProviderCfg().hasKey || root.currentProviderCfg().hasEnvKey)
                      ? root.accentColor
                      : Util.alpha(root.fgColor, 0.68)
                    font.family: root.uiFont
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }

                Row {
                  id: provActionsRow
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xs

                  Ui.Button {
                    visible: String(root.currentProviderMeta().keyUrl || "").length > 0
                    text: strings.t("settings.getApiKey")
                    fontSize: Style.font.caption
                    bordered: true
                    onClicked: root.openKeyConsole(root.selectedProvider)
                  }

                  Ui.Button {
                    text: root.testingProvider ? strings.t("settings.testing") : strings.t("settings.testConnection")
                    iconText: "󰙨"
                    iconSpinning: root.testingProvider
                    fontSize: Style.font.caption
                    bordered: true
                    selected: true
                    onClicked: root.testSelectedProvider()
                  }
                }
              }

              // Inline test result banner
              PlainText {
                visible: root.providerTestText.length > 0
                width: parent.width
                text: root.providerTestText
                color: root.providerTestOk ? root.accentColor : root.urgentColor
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
                font.bold: true
                wrapMode: Text.Wrap
              }

              // Model dropdown + refresh button
              Row {
                id: modelRow
                width: parent.width
                spacing: Style.spacing.xs

                Ui.Dropdown {
                  width: modelRow.width - refreshModelsBtn.implicitWidth - modelRow.spacing
                  label: strings.t("settings.modelLabel")
                  value: String(root.currentProviderCfg().model || root.currentProviderMeta().defaultModel || "")
                  options: root.currentProviderModels()
                  foreground: root.fgColor
                  background: root.bgColor
                  accent: root.accentColor
                  onChanged: function(nextModel) {
                    root.saveProviderField(root.selectedProvider, { model: nextModel })
                  }
                }

                Ui.Button {
                  id: refreshModelsBtn
                  anchors.bottom: parent.bottom
                  iconText: "󰑐"
                  iconSpinning: root.refreshingModels
                  bordered: true
                  tooltipText: strings.t("settings.refreshModels")
                  onClicked: root.refreshModelsFor(root.selectedProvider)
                }
              }

              // Custom model ID override
              Row {
                id: customModelRow
                width: parent.width
                spacing: Style.spacing.xs

                Ui.TextField {
                  width: customModelRow.width - saveModelBtn.implicitWidth - customModelRow.spacing
                  text: root.customModelDraft
                  placeholderText: strings.t("settings.customModelPlaceholder")
                  foreground: root.fgColor
                  accent: root.accentColor
                  onTextEdited: root.customModelDraft = text
                  onAccepted: {
                    var m = root.customModelDraft.trim()
                    if (m) {
                      root.saveProviderField(root.selectedProvider, { model: m })
                      root.customModelDraft = ""
                    }
                  }
                  Keys.onEscapePressed: root.close()
                }

                Ui.Button {
                  id: saveModelBtn
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("settings.save")
                  fontSize: Style.font.caption
                  bordered: true
                  onClicked: {
                    var m = root.customModelDraft.trim()
                    if (m) {
                      root.saveProviderField(root.selectedProvider, { model: m })
                      root.customModelDraft = ""
                    }
                  }
                }
              }

              // Masked API key editor (Gemini / Anthropic / OpenAI)
              Column {
                visible: root.currentProviderMeta().requiresKey === true
                width: parent.width
                spacing: Style.spacing.xs

                PlainText {
                  text: strings.t("settings.apiKeyLabel")
                  color: Util.alpha(root.fgColor, 0.72)
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Row {
                  id: apiKeyRow
                  width: parent.width
                  spacing: Style.spacing.xs

                  Ui.TextField {
                    width: apiKeyRow.width - saveKeyBtn.implicitWidth - (clearKeyBtn.visible ? clearKeyBtn.implicitWidth + apiKeyRow.spacing : 0) - apiKeyRow.spacing
                    password: true
                    text: root.apiKeyDraft
                    placeholderText: root.currentProviderCfg().hasKey
                      ? strings.t("settings.apiKeySavedPlaceholder").arg(String(root.currentProviderCfg().maskedKey || "••••"))
                      : strings.t("settings.apiKeyPlaceholder")
                    foreground: root.fgColor
                    accent: root.accentColor
                    onTextEdited: root.apiKeyDraft = text
                    onAccepted: {
                      var k = root.apiKeyDraft.trim()
                      if (k) {
                        root.saveProviderField(root.selectedProvider, { apiKey: k })
                        root.apiKeyDraft = ""
                      }
                    }
                    Keys.onEscapePressed: root.close()
                  }

                  Ui.Button {
                    id: saveKeyBtn
                    anchors.verticalCenter: parent.verticalCenter
                    text: strings.t("settings.save")
                    fontSize: Style.font.caption
                    bordered: true
                    selected: root.apiKeyDraft.trim().length > 0
                    onClicked: {
                      var k = root.apiKeyDraft.trim()
                      if (k) {
                        root.saveProviderField(root.selectedProvider, { apiKey: k })
                        root.apiKeyDraft = ""
                      }
                    }
                  }

                  Ui.Button {
                    id: clearKeyBtn
                    visible: root.currentProviderCfg().hasKey === true
                    anchors.verticalCenter: parent.verticalCenter
                    text: strings.t("settings.clear")
                    fontSize: Style.font.caption
                    bordered: true
                    onClicked: {
                      root.apiKeyDraft = ""
                      root.saveProviderField(root.selectedProvider, { apiKey: "" })
                    }
                  }
                }
              }

              // Ollama server URL editor
              Column {
                visible: root.selectedProvider === "ollama"
                width: parent.width
                spacing: Style.spacing.xs

                PlainText {
                  text: strings.t("settings.ollamaHostLabel")
                  color: Util.alpha(root.fgColor, 0.72)
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Row {
                  id: ollamaRow
                  width: parent.width
                  spacing: Style.spacing.xs

                  Ui.TextField {
                    width: ollamaRow.width - saveOllamaBtn.implicitWidth - ollamaRow.spacing
                    text: root.ollamaHostDraft
                    placeholderText: "http://127.0.0.1:11434"
                    foreground: root.fgColor
                    accent: root.accentColor
                    onTextEdited: root.ollamaHostDraft = text
                    onAccepted: root.saveProviderField("ollama", { host: root.ollamaHostDraft.trim() })
                    Keys.onEscapePressed: root.close()
                  }

                  Ui.Button {
                    id: saveOllamaBtn
                    anchors.verticalCenter: parent.verticalCenter
                    text: strings.t("settings.save")
                    fontSize: Style.font.caption
                    bordered: true
                    onClicked: root.saveProviderField("ollama", { host: root.ollamaHostDraft.trim() })
                  }
                }
              }

              // Omarchy CLI agent selector
              Column {
                visible: root.selectedProvider === "agent"
                width: parent.width
                spacing: Style.spacing.xs

                PlainText {
                  text: strings.t("settings.cliAgentLabel")
                  color: Util.alpha(root.fgColor, 0.72)
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Flow {
                  width: parent.width
                  spacing: Style.spacing.xs

                  Repeater {
                    model: Array.isArray(root.currentProviderMeta().clis)
                      ? root.currentProviderMeta().clis
                      : ["default", "claude", "codex", "agy", "opencode", "grok", "gemini"]
                    delegate: Ui.Button {
                      text: modelData
                      fontSize: Style.font.caption
                      bordered: true
                      selected: String(root.currentProviderCfg().cli || "default") === modelData
                      onClicked: root.saveProviderField("agent", { cli: modelData })
                    }
                  }
                }
              }
            }
          }
        }

        // ============================================================ TASKS TAB
        Column {
          visible: root.activeTab === "tasks"
          width: parent.width
          spacing: Style.spacing.sm

          Item {
            width: parent.width
            implicitHeight: Math.max(routingLabel.implicitHeight, routingSwitch.implicitHeight)

            PlainText {
              id: routingLabel
              anchors.left: parent.left
              anchors.right: routingSwitch.left
              anchors.rightMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: strings.t("settings.enableTaskRouting")
              color: root.fgColor
              font.family: root.uiFont
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Ui.ToggleSwitch {
              id: routingSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: !!(root.config && root.config.taskRouting && root.config.taskRouting.enabled)
              foreground: root.fgColor
              accent: root.accentColor
              onToggled: root.patchConfig({
                taskRouting: {
                  enabled: !(root.config && root.config.taskRouting && root.config.taskRouting.enabled)
                }
              })
            }
          }

          Repeater {
            model: [
              { key: "general", label: strings.t("settings.task.general") },
              { key: "vision", label: strings.t("settings.task.vision") },
              { key: "text", label: strings.t("settings.task.text") },
              { key: "translate", label: strings.t("settings.task.translate") },
              { key: "handoffAgent", label: strings.t("settings.task.handoff") }
            ]
            delegate: Rectangle {
              width: panelColumn.width
              radius: Math.min(4, root.cornerRadius)
              color: Util.alpha(root.fgColor, 0.05)
              border.width: 1
              border.color: Util.alpha(root.fgColor, 0.14)
              implicitHeight: taskRow.implicitHeight + Style.spacing.xs * 2

              Item {
                id: taskRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.spacing.sm
                implicitHeight: Math.max(taskTitle.implicitHeight, taskVal.implicitHeight)

                PlainText {
                  id: taskTitle
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.label
                  color: root.fgColor
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                PlainText {
                  id: taskVal
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.taskSummary(modelData.key)
                  color: root.accentColor
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // ============================================================ LANGUAGE & OCR TAB
        Column {
          visible: root.activeTab === "language"
          width: parent.width
          spacing: Style.spacing.sm

          Ui.PanelSectionHeader {
            text: strings.t("settings.translateLanguage")
            foreground: root.fgColor
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: ["English", "Spanish", "French", "German", "Portuguese", "Japanese"]
              delegate: Ui.Button {
                text: modelData
                fontSize: Style.font.bodySmall
                bordered: true
                selected: root.cfgVal("translateLanguage", "English") === modelData
                onClicked: root.patchConfig({ translateLanguage: modelData })
              }
            }
          }

          Ui.PanelSectionHeader {
            text: strings.t("settings.ocrLanguages")
            foreground: root.fgColor
          }

          PlainText {
            width: parent.width
            text: strings.t("settings.ocrActive").arg((root.cfgVal("ocrLanguages", ["eng"]) || ["eng"]).join(" + "))
            color: Util.alpha(root.fgColor, 0.8)
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
          }
        }

        // Footer status line
        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(root.fgColor, 0.14)
        }

        PlainText {
          width: parent.width
          text: root.statusText
            ? root.statusText
            : strings.t("settings.footerHint")
          color: root.statusError ? root.urgentColor : (root.statusText ? root.accentColor : Util.alpha(root.fgColor, 0.58))
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }
    }
  }
}
