import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "ScreenLensLogic.js" as Logic
import "ui" as SLUi
import "tabs" as SLTabs

// Reel-inspired tabbed Settings panel for ScreenLens.
// Left-clicking the bar icon opens Settings; right-clicking launches the
// fullscreen ScreenLens overlay immediately. Also reachable from the overlay's
// top-bar gear button via `omarchy-shell screenlens-settings open`.
Ui.Panel {
  id: root
  moduleName: "io.github.cgranier.screenlens"
  ipcTarget: "screenlens-settings"
  manageIpc: false

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string themeMode: String(root.cfgVal("theme", "system"))
  readonly property var resolvedPalette: Logic.resolveThemePalette(root.themeMode, {
    background: Commons.Color.popups.background,
    text: Commons.Color.popups.text,
    border: Commons.Color.popups.border,
    scrim: Commons.Color.menu.scrim,
    accent: Commons.Color.accent,
    urgent: Commons.Color.urgent
  })
  readonly property color bgColor: resolvedPalette.background
  readonly property color fgColor: resolvedPalette.text
  readonly property color accentColor: resolvedPalette.accent
  readonly property color urgentColor: resolvedPalette.urgent
  readonly property color borderColor: resolvedPalette.border
  readonly property color onAccentInk: Logic.inkOn(String(accentColor))
  readonly property color cardFill: Util.alpha(fgColor, 0.03)
  readonly property color cardBorder: Util.alpha(fgColor, 0.08)
  readonly property color restFill: Util.alpha(fgColor, 0.045)
  readonly property color hoverFill: Util.alpha(fgColor, 0.09)
  readonly property color hairline: Util.alpha(fgColor, 0.12)
  readonly property color rowDivider: Util.alpha(fgColor, 0.06)
  readonly property color mutedInk: Util.alpha(fgColor, 0.50)
  readonly property color secondaryInk: Util.alpha(fgColor, 0.72)
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string uiFont: Style.font.family

  property string activeTab: "general" // "general" | "providers" | "tasks" | "actions" | "language"
  readonly property var tabIds: ["general", "providers", "tasks", "actions", "language"]

  // Live config state loaded from 0600 ~/.config/omarchy/screenlens.json
  property var config: ({})
  property var catalog: ({})
  property string omarchyDefaultAgent: ""
  property string keybindDraft: "SUPER + ALT + A"
  property string voiceKeybindDraft: "SUPER + ALT + V"
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

  // Language & OCR tab state
  property string customTranslateLangDraft: ""
  property var ocrInstalled: []
  property var ocrAvailable: []
  property string selectedOcrInstallCode: ""
  property bool installingOcrPack: false

  // Custom Quick Actions tab state (Alt+1..4)
  property int selectedChipIndex: 0
  property string chipLabelDraft: ""
  property string chipIconDraft: "󰋗"
  property string chipActionDraft: "prompt"
  property string chipTaskDraft: "auto"
  property string chipPromptDraft: ""
  property var defaultQuickChips: Logic.DEFAULT_QUICK_CHIPS
  property var quickChipPresets: Logic.DEFAULT_QUICK_CHIPS

  // Update check state (cached hourly via scripts/updater.py)
  property bool updateChecking: false
  property bool updateAvailable: false
  property int updateBehind: 0
  property bool updateManaged: true
  property string updateError: ""
  property int updateSweepTick: 0
  property bool updateCheckedThisOpen: false

  // Ephemeral in-memory state (RAM only — never persisted to disk)
  property bool pinnedVisible: false
  property var pinnedNote: null
  property var lastThread: null
  property string pendingEphemWriteJson: ""
  property string pendingEphemPurpose: "" // "continue" | "restore"

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
    function showPinFromFile(path: string): void { root.readEphemIntoPin(path) }
    function resumePin(): void {
      if (root.pinnedNote) root.pinnedVisible = true
    }
    function closePin(): void { root.closePinnedNote() }
    function stashLastThread(path: string): void { root.readEphemIntoLastThread(path) }
    function restoreLastThread(): void { root.sendLastThreadToOverlay() }
  }

  onOpenedChanged: {
    if (opened) {
      root.statusText = ""
      root.statusError = false
      root.updateCheckedThisOpen = false
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
    Util.execArgv(["omarchy-shell", "shell", "summon", root.moduleName, "{}"])
  }

  function launchVoiceCapture() {
    root.close()
    Util.execArgv(["omarchy-shell", "shell", "summon", root.moduleName, '{"voice":true}'])
  }

  function loadState() {
    loadConfigProc.running = false
    loadConfigProc.running = true
    ocrStatusProc.running = false
    ocrStatusProc.running = true
    if (Object.keys(root.catalog).length === 0) {
      loadCatalogProc.running = false
      loadCatalogProc.running = true
    }
  }

  function readEphemIntoPin(path) {
    var clean = String(path || "").trim()
    if (!clean) return
    if (Object.keys(root.config || ({})).length === 0) {
      loadConfigProc.running = false
      loadConfigProc.running = true
    }
    ephemReadPinProc.command = ["/usr/bin/python3", root.pluginDir + "/scripts/actions.py", "ephem-read", clean]
    ephemReadPinProc.running = false
    ephemReadPinProc.running = true
  }

  function readEphemIntoLastThread(path) {
    var clean = String(path || "").trim()
    if (!clean) return
    ephemReadLastProc.command = ["/usr/bin/python3", root.pluginDir + "/scripts/actions.py", "ephem-read", clean]
    ephemReadLastProc.running = false
    ephemReadLastProc.running = true
  }

  function closePinnedNote() {
    root.pinnedVisible = false
    root.pinnedNote = null
  }

  function continuePinnedOnLiveScreen(pinned) {
    var note = pinned || root.pinnedNote
    if (!note) return
    // Hide the floating mini card while the overlay is open, but keep pinnedNote
    // alive in RAM so Esc brings it right back and follow-ups update it cleanly.
    root.pinnedVisible = false
    root.pendingEphemPurpose = "continue"
    root.pendingEphemWriteJson = JSON.stringify(note)
    ephemWriteProc.running = false
    ephemWriteProc.running = true
  }

  function sendLastThreadToOverlay() {
    if (!root.lastThread) return
    root.pendingEphemPurpose = "restore"
    root.pendingEphemWriteJson = JSON.stringify(root.lastThread)
    ephemWriteProc.running = false
    ephemWriteProc.running = true
  }

  function selectQuickChipSlot(idx) {
    var chips = Logic.resolveQuickChips(root.config, {
      explain: strings.t("chip.explain"),
      summarize: strings.t("chip.summarize"),
      translate: strings.t("chip.translate"),
      extract: strings.t("chip.extractText")
    })
    var clamped = Math.max(0, Math.min(3, Number(idx) || 0))
    root.selectedChipIndex = clamped
    var c = chips[clamped] || Logic.DEFAULT_QUICK_CHIPS[clamped]
    root.chipLabelDraft = String(c.label || "")
    root.chipIconDraft = String(c.icon || "󰋗")
    root.chipActionDraft = String(c.action || "prompt")
    root.chipTaskDraft = String(c.task || "auto")
    root.chipPromptDraft = String(c.prompt || "")
  }

  function applyQuickChipPreset(preset) {
    if (!preset) return
    root.chipLabelDraft = String(preset.label || "")
    root.chipIconDraft = String(preset.icon || "󰋗")
    root.chipActionDraft = String(preset.action || "prompt")
    root.chipTaskDraft = String(preset.task || "auto")
    root.chipPromptDraft = String(preset.prompt || "")
  }

  function saveQuickChipSlot() {
    var chips = Logic.resolveQuickChips(root.config, {
      explain: strings.t("chip.explain"),
      summarize: strings.t("chip.summarize"),
      translate: strings.t("chip.translate"),
      extract: strings.t("chip.extractText")
    })
    var idx = Math.max(0, Math.min(3, root.selectedChipIndex))
    var out = []
    for (var i = 0; i < 4; i++) {
      var src = chips[i]
      if (i === idx) {
        var act = root.chipActionDraft === "extract_text" ? "extract_text" : "prompt"
        var cleanLabel = String(root.chipLabelDraft || "").trim() || src.label
        out.push({
          id: cleanLabel.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 24) || ("chip-" + (i + 1)),
          label: cleanLabel.slice(0, 28),
          icon: String(root.chipIconDraft || "").trim().slice(0, 4) || src.icon,
          action: act,
          task: act === "extract_text" ? "text" : String(root.chipTaskDraft || "auto"),
          prompt: act === "extract_text" ? "" : String(root.chipPromptDraft || "").trim().slice(0, 1200)
        })
      } else {
        out.push({
          id: src.id,
          label: src.label,
          icon: src.icon,
          action: src.action,
          task: src.task,
          prompt: src.prompt
        })
      }
    }
    root.patchConfig({ quickChips: out })
  }

  function resetQuickChips() {
    var defs = Array.isArray(root.defaultQuickChips) && root.defaultQuickChips.length === 4
      ? root.defaultQuickChips
      : Logic.DEFAULT_QUICK_CHIPS
    root.patchConfig({ quickChips: defs })
    root.setStatus(strings.t("settings.actionsResetDone"), false)
  }

  function isOcrLangActive(code) {
    var active = root.cfgVal("ocrLanguages", ["eng"])
    return Array.isArray(active) && active.indexOf(code) !== -1
  }

  function toggleOcrLang(code) {
    var cur = root.cfgVal("ocrLanguages", ["eng"])
    var list = Array.isArray(cur) ? cur.slice() : ["eng"]
    var idx = list.indexOf(code)
    if (idx !== -1) {
      if (list.length <= 1) {
        root.setStatus(strings.t("settings.ocrMinOne"), true)
        return
      }
      list.splice(idx, 1)
    } else {
      list.push(code)
    }
    root.patchConfig({ ocrLanguages: list })
  }

  function ocrAvailableOptions() {
    var opts = []
    for (var i = 0; i < root.ocrAvailable.length; i++) {
      var item = root.ocrAvailable[i]
      opts.push({ value: item.code, label: item.name + " (" + item.code + ")" })
    }
    return opts
  }

  function installSelectedOcrPack() {
    if (root.installingOcrPack || !root.selectedOcrInstallCode) return
    root.installingOcrPack = true
    root.setStatus(strings.t("settings.ocrInstalling").arg("tesseract-data-" + root.selectedOcrInstallCode), false)
    ocrInstallProc.command = [
      "/usr/bin/python3",
      root.pluginDir + "/scripts/ocr_langs.py",
      "install",
      root.selectedOcrInstallCode
    ]
    ocrInstallProc.running = false
    ocrInstallProc.running = true
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

  function effectiveAgentCli(cliValue) {
    var c = String(cliValue || "default").trim().toLowerCase()
    if (c && c !== "default") return c
    return root.omarchyDefaultAgent || "claude"
  }

  function agentModelsForCli(cliValue) {
    var eff = root.effectiveAgentCli(cliValue)
    var liveKey = "agent:" + eff
    var live = root.discoveredModels[liveKey]
    if (Array.isArray(live) && live.length > 0) return live.slice()
    var meta = (root.catalog && root.catalog.agent) ? root.catalog.agent : ({})
    var byCli = meta.modelsByCli || ({})
    if (Array.isArray(byCli[eff]) && byCli[eff].length > 0) return byCli[eff].slice()
    return ["default"]
  }

  function currentProviderModels() {
    if (root.selectedProvider === "agent") {
      var cliVal = String(currentProviderCfg().cli || "default")
      var cliBase = root.agentModelsForCli(cliVal)
      var activeAgentModel = String(currentProviderCfg().model || "")
      if (activeAgentModel && cliBase.indexOf(activeAgentModel) === -1) cliBase.unshift(activeAgentModel)
      return cliBase
    }
    var live = root.discoveredModels[root.selectedProvider]
    var base = Array.isArray(live) && live.length > 0
      ? live.slice()
      : (Array.isArray(currentProviderMeta().models) ? currentProviderMeta().models.slice() : [])
    var active = String(currentProviderCfg().model || "")
    if (active && base.indexOf(active) === -1) base.unshift(active)
    return base
  }

  function providerReady(provId) {
    var provs = (root.config && root.config.providers) ? root.config.providers : ({})
    var p = provs[provId] || ({})
    if (provId === "ollama" || provId === "agent") return true
    return !!(p.hasKey || p.hasEnvKey)
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

  function refreshModelsFor(provId, cliOverride) {
    if (root.refreshingModels) return
    root.refreshingModels = true
    var cmd = ["/usr/bin/python3", root.pluginDir + "/scripts/providers.py", "list-models", provId]
    if (provId === "agent") {
      var cliArg = cliOverride || String(currentProviderCfg().cli || "default")
      cmd.push("--cli")
      cmd.push(cliArg)
    }
    listModelsProc.command = cmd
    listModelsProc.running = false
    listModelsProc.running = true
  }

  function selectAgentCli(nextCli) {
    var nextModels = root.agentModelsForCli(nextCli)
    var curModel = String(currentProviderCfg().model || "")
    var fields = { cli: nextCli }
    if (curModel && nextModels.indexOf(curModel) === -1) {
      fields.model = "default"
    }
    root.saveProviderField("agent", fields)
    var eff = root.effectiveAgentCli(nextCli)
    if ((eff === "agy" || eff === "opencode" || eff === "grok") && !root.discoveredModels["agent:" + eff]) {
      root.refreshModelsFor("agent", nextCli)
    }
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
      chord,
      "--ensure-layer-rule"
    ]
    if (root.rebindExisting) cmd.push("--rebind")
    keybindProc.command = cmd
    keybindProc.running = false
    keybindProc.running = true
  }

  function applyVoiceKeybind() {
    var chord = String(root.voiceKeybindDraft || "").trim()
    root.busy = true
    var cmd = [
      "/usr/bin/python3",
      root.pluginDir + "/scripts/config.py",
      "set-voice-keybind",
      "--ensure-layer-rule"
    ]
    if (chord) {
      cmd.push(chord)
    } else {
      cmd.push("--clear")
    }
    if (root.rebindExisting) cmd.push("--rebind")
    voiceKeybindProc.command = cmd
    voiceKeybindProc.running = false
    voiceKeybindProc.running = true
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

  function taskEntry(taskKey) {
    var routing = (root.config && root.config.taskRouting) ? root.config.taskRouting : ({})
    return (routing[taskKey] && typeof routing[taskKey] === "object") ? routing[taskKey] : ({})
  }

  function taskProviderValue(taskKey) {
    return String(taskEntry(taskKey).provider || "")
  }

  function taskModelValue(taskKey) {
    return String(taskEntry(taskKey).model || "")
  }

  function taskModelOptions(taskKey) {
    var opts = [{ value: "", label: strings.t("settings.providerDefault") }]
    var prov = taskProviderValue(taskKey)
    if (!prov || prov === "auto") prov = String(root.cfgVal("defaultProvider", "auto"))
    if (prov === "auto") return opts
    var list = []
    if (prov === "agent") {
      var agentCli = (root.config && root.config.providers && root.config.providers.agent)
        ? String(root.config.providers.agent.cli || "default")
        : "default"
      list = root.agentModelsForCli(agentCli)
    } else {
      var live = root.discoveredModels[prov]
      var meta = (root.catalog && root.catalog[prov]) ? root.catalog[prov] : ({})
      list = Array.isArray(live) && live.length > 0
        ? live
        : (Array.isArray(meta.models) ? meta.models : [])
    }
    for (var i = 0; i < list.length; i++) {
      opts.push({ value: String(list[i]), label: String(list[i]) })
    }
    var current = taskModelValue(taskKey)
    if (current) {
      var found = false
      for (var j = 0; j < opts.length; j++) {
        if (opts[j].value === current) { found = true; break }
      }
      if (!found) opts.push({ value: current, label: current })
    }
    return opts
  }

  function saveTaskRouting(taskKey, fields) {
    var patch = { taskRouting: {} }
    patch.taskRouting[taskKey] = fields
    root.patchConfig(patch)
  }

  function checkForUpdates(force) {
    if (root.updateChecking) return
    root.updateChecking = true
    root.updateError = ""
    var cmd = ["/usr/bin/python3", root.pluginDir + "/scripts/updater.py", "check"]
    if (force) cmd.push("--force")
    updateCheckProc.command = cmd
    updateCheckProc.running = false
    updateCheckProc.running = true
  }

  function applyUpdate() {
    if (!root.updateManaged) {
      root.setStatus(strings.t("settings.updateUnmanaged"), false)
      return
    }
    root.close()
    Util.execArgv(["/usr/bin/python3", root.pluginDir + "/scripts/updater.py", "apply"])
  }

  function updateTooltipText() {
    if (root.updateChecking) return strings.t("settings.updateChecking")
    if (root.updateError) return strings.t("settings.updateFailed").arg(root.updateError)
    if (!root.updateManaged) return strings.t("settings.updateUnmanaged")
    if (root.updateAvailable && root.updateBehind > 0) {
      return strings.tn("settings.updateAvailable", root.updateBehind).arg(Commons.I18n.formatNumber(root.updateBehind))
    }
    return strings.t("settings.updateUpToDate")
  }

  Timer {
    id: updateSweepTimer
    interval: 100
    repeat: true
    running: root.updateChecking
    onTriggered: root.updateSweepTick = (root.updateSweepTick + 1) % 1000
  }

  Process {
    id: updateCheckProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.updateChecking = false
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok) {
          root.updateManaged = res.managed !== false
          root.updateAvailable = res.available === true
          root.updateBehind = Number(res.behind || 0)
          root.updateError = ""
        } else {
          root.updateError = (res && res.error) ? String(res.error) : "fetch failed"
        }
      }
    }
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
          root.voiceKeybindDraft = String(res.config.voiceKeybind || "")
          var ol = (res.config.providers && res.config.providers.ollama) ? res.config.providers.ollama : ({})
          root.ollamaHostDraft = String(ol.host || "http://127.0.0.1:11434")
          root.selectQuickChipSlot(root.selectedChipIndex)
          if (root.opened && !root.updateCheckedThisOpen && res.config.autoCheckUpdates !== false) {
            root.updateCheckedThisOpen = true
            root.checkForUpdates(false)
          }
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
          root.omarchyDefaultAgent = String(res.defaultAgent || "")
          if (Array.isArray(res.defaultQuickChips) && res.defaultQuickChips.length === 4) {
            root.defaultQuickChips = res.defaultQuickChips
          }
          if (Array.isArray(res.quickChipPresets) && res.quickChipPresets.length > 0) {
            root.quickChipPresets = res.quickChipPresets
          }
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
          root.selectQuickChipSlot(root.selectedChipIndex)
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
          var cacheKey = (res.provider === "agent" && res.effectiveCli)
            ? ("agent:" + res.effectiveCli)
            : res.provider
          next[cacheKey] = res.models
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
    id: ocrStatusProc
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/ocr_langs.py", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok) {
          root.ocrInstalled = Array.isArray(res.installed) ? res.installed : []
          root.ocrAvailable = Array.isArray(res.available) ? res.available : []
          if (root.ocrAvailable.length > 0 && !root.selectedOcrInstallCode) {
            root.selectedOcrInstallCode = root.ocrAvailable[0].code
          }
        }
      }
    }
  }

  Process {
    id: ocrInstallProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.installingOcrPack = false
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok) {
          root.ocrInstalled = Array.isArray(res.installed) ? res.installed : root.ocrInstalled
          root.ocrAvailable = Array.isArray(res.available) ? res.available : root.ocrAvailable
          root.selectedOcrInstallCode = root.ocrAvailable.length > 0 ? root.ocrAvailable[0].code : ""
          root.loadState()
          root.setStatus(strings.t("settings.ocrInstalled").arg(String(res.installedPkg || "pack")), false)
        } else {
          root.setStatus((res && res.error) ? res.error : strings.t("settings.ocrInstallFailed"), true)
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

  Process {
    id: voiceKeybindProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok) {
          root.voiceKeybindDraft = String(res.voiceKeybind || "")
          root.loadState()
          root.setStatus(
            res.voiceKeybind
              ? strings.t("settings.voiceKeybindApplied").arg(res.voiceKeybind)
              : strings.t("settings.voiceKeybindCleared"),
            false
          )
        } else {
          root.setStatus((res && res.error) ? res.error : strings.t("settings.keybindFailed"), true)
        }
      }
    }
  }

  Process {
    id: ephemReadPinProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.data && (res.data.answer || (Array.isArray(res.data.messages) && res.data.messages.length > 0))) {
          root.pinnedNote = res.data
          root.lastThread = res.data
          root.pinnedVisible = true
        }
      }
    }
  }

  Process {
    id: ephemReadLastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.data && Array.isArray(res.data.messages) && res.data.messages.length > 0) {
          root.lastThread = res.data
        }
      }
    }
  }

  Process {
    id: ephemWriteProc
    stdinEnabled: true
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/actions.py", "ephem-write", "-"]
    onStarted: ephemWriteProc.write(root.pendingEphemWriteJson + "\n")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var purpose = root.pendingEphemPurpose
        root.pendingEphemPurpose = ""
        root.pendingEphemWriteJson = ""
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.path) {
          var payload = (purpose === "continue")
            ? JSON.stringify({ continueFile: res.path })
            : JSON.stringify({ restoreFile: res.path })
          Util.execArgv(["omarchy-shell", "shell", "summon", root.moduleName, payload])
        } else if (purpose === "continue" && root.pinnedNote) {
          root.pinnedVisible = true
        }
      }
    }
  }

  SLUi.PinnedAnswerCard {
    id: pinnedCard
    shown: root.pinnedVisible
    pinnedData: root.pinnedNote
    bgColor: root.bgColor
    fgColor: root.fgColor
    accentColor: root.accentColor
    borderColor: root.borderColor
    hairlineColor: root.hairline
    hoverFill: root.hoverFill
    mutedInk: root.mutedInk
    cornerRadius: root.cornerRadius
    uiFont: root.uiFont
    themeMode: root.themeMode
    strings: strings
    onCopyRequested: function(txt) {
      Quickshell.execDetached(["wl-copy", "--", String(txt || "").slice(0, 65536)])
    }
    onReexpandRequested: function(pinned) { root.continuePinnedOnLiveScreen(pinned) }
    onCloseRequested: root.closePinnedNote()
  }

  // Top-bar widget icon: custom crisp vector viewfinder mark.
  // Left-click toggles Settings, right-click captures screen immediately.
  Ui.BarIconButton {
    id: barButton
    bar: root.bar
    active: root.opened
    foreground: root.barForeground
    activeColor: root.accentColor
    tooltipText: strings.t("settings.barTooltip")
    iconComponent: Component {
      SLUi.LensMark {
        inkColor: barButton.active ? root.accentColor : root.barForeground
        dotColor: barButton.active ? root.accentColor : root.barForeground
      }
    }
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
    contentWidth: Style.space(480)
    contentHeight: Style.space(520)
    focusTarget: panelKeyCatcher

    Item {
      id: panelKeyCatcher
      anchors.fill: parent
      focus: true

      // Surface backdrop when Dark or Light override is chosen (System uses
      // KeyboardPanel's native themed/glassy background).
      Rectangle {
        anchors.fill: parent
        anchors.margins: -Style.spacing.popupPadding
        visible: root.themeMode !== "system"
        color: root.bgColor
        radius: root.cornerRadius
        border.width: 1
        border.color: root.borderColor
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          root.cycleTab(1)
          bodyFlick.contentY = 0
          event.accepted = true
        } else if (event.key === Qt.Key_Backtab) {
          root.cycleTab(-1)
          bodyFlick.contentY = 0
          event.accepted = true
        } else if (event.key === Qt.Key_C && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
          root.launchCapture()
          event.accepted = true
        } else if (event.key === Qt.Key_V && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
          root.launchVoiceCapture()
          event.accepted = true
        } else if (event.key === Qt.Key_U && (event.modifiers & Qt.ShiftModifier) && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
          if (root.updateAvailable) root.applyUpdate()
          else root.checkForUpdates(true)
          event.accepted = true
        }
      }

      ColumnLayout {
        id: frameLayout
        anchors.fill: parent
        spacing: Style.space(8)

        // ============================================================ FIXED HEADER
        Item {
          Layout.fillWidth: true
          implicitHeight: Style.space(34)

          Row {
            id: headerLeft
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            SLUi.LensMark {
              anchors.verticalCenter: parent.verticalCenter
              iconSize: Style.space(18)
              inkColor: root.fgColor
              dotColor: root.accentColor
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
            spacing: Style.space(6)

            // Quick hands-free Voice-to-ScreenLens launch button (shortcut: v)
            Rectangle {
              id: voiceLaunchBtn
              anchors.verticalCenter: parent.verticalCenter
              radius: Math.min(4, root.cornerRadius)
              color: voiceLaunchHover.hovered ? root.hoverFill : root.restFill
              border.width: 1
              border.color: voiceLaunchHover.hovered ? Util.alpha(root.accentColor, 0.55) : root.hairline
              implicitWidth: voiceLaunchRow.implicitWidth + Style.space(14)
              implicitHeight: Style.space(28)

              Row {
                id: voiceLaunchRow
                anchors.centerIn: parent
                spacing: Style.space(5)

                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰍬"
                  color: voiceLaunchHover.hovered ? root.accentColor : root.fgColor
                  font.family: root.uiFont
                  font.pixelSize: Style.font.body
                }

                SLUi.KeyCap {
                  anchors.verticalCenter: parent.verticalCenter
                  label: "v"
                  fgColor: root.fgColor
                  cornerRadius: root.cornerRadius
                  uiFont: root.uiFont
                }
              }

              HoverHandler { id: voiceLaunchHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.launchVoiceCapture()
              }

              Ui.PanelToolTip {
                visible: voiceLaunchHover.hovered
                text: strings.t("settings.voiceAskTooltip")
              }
            }

            // Primary Capture button (Reel-style solid accent with subtle vertical shade)
            Rectangle {
              id: captureBtn
              anchors.verticalCenter: parent.verticalCenter
              radius: Math.min(4, root.cornerRadius)
              implicitWidth: captureBtnRow.implicitWidth + Style.space(18)
              implicitHeight: Style.space(28)
              scale: captureMouse.pressed ? 0.98 : 1.0
              Behavior on scale { NumberAnimation { duration: Style.duration(90); easing.type: Easing.OutCubic } }

              gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.lighter(root.accentColor, captureHover.hovered ? 1.12 : 1.05) }
                GradientStop { position: 1.0; color: Qt.darker(root.accentColor, 1.06) }
              }

              // Subtle 1 px top sheen highlight
              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#33ffffff"
              }

              Row {
                id: captureBtnRow
                anchors.centerIn: parent
                spacing: Style.space(6)

                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰒅"
                  color: root.onAccentInk
                  font.family: root.uiFont
                  font.pixelSize: Style.font.body
                }

                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("settings.captureNow")
                  color: root.onAccentInk
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                SLUi.KeyCap {
                  anchors.verticalCenter: parent.verticalCenter
                  label: "c"
                  fgColor: root.fgColor
                  cornerRadius: root.cornerRadius
                  uiFont: root.uiFont
                  capTextColor: root.onAccentInk
                  capBg: Util.alpha(root.onAccentInk, 0.14)
                  capBorder: Util.alpha(root.onAccentInk, 0.28)
                }
              }

              HoverHandler { id: captureHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                id: captureMouse
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.launchCapture()
              }
            }

            // Quiet bare close button
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(26)
              height: Style.space(26)
              radius: Math.min(4, root.cornerRadius)
              color: closeHover.hovered ? root.hoverFill : "transparent"

              PlainText {
                anchors.centerIn: parent
                text: "󰅖"
                color: closeHover.hovered ? root.fgColor : root.mutedInk
                font.family: root.uiFont
                font.pixelSize: Style.font.body
              }

              HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.close()
              }
            }
          }
        }

        // ============================================================ FIXED UNDERLINED TAB STRIP
        Item {
          Layout.fillWidth: true
          implicitHeight: Style.space(31)

          Row {
            id: tabStripRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Style.space(30)

            Repeater {
              model: [
                { id: "general",   icon: "󰒓", label: strings.t("settings.tab.general") },
                { id: "providers", icon: "󰚩", label: strings.t("settings.tab.providers") },
                { id: "tasks",     icon: "󰒋", label: strings.t("settings.tab.tasks") },
                { id: "actions",   icon: "󰉁", label: strings.t("settings.tab.actions") },
                { id: "language",  icon: "󰗊", label: strings.t("settings.tab.language") }
              ]
              delegate: Item {
                id: tabItem
                required property var modelData
                readonly property bool isActive: root.activeTab === modelData.id
                width: tabStripRow.width / root.tabIds.length
                height: tabStripRow.height

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  PlainText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: tabItem.modelData.icon
                    color: tabItem.isActive ? root.accentColor : (tabHover.hovered ? root.fgColor : root.mutedInk)
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                  }

                  PlainText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: tabItem.modelData.label
                    color: tabItem.isActive ? root.fgColor : (tabHover.hovered ? root.fgColor : Util.alpha(root.fgColor, 0.58))
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                    font.bold: tabItem.isActive
                  }
                }

                // Active 2 px accent underline (inset) / subtle hover hairline
                Rectangle {
                  anchors.bottom: parent.bottom
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  height: tabItem.isActive ? 2 : (tabHover.hovered ? 1 : 0)
                  color: tabItem.isActive ? root.accentColor : Util.alpha(root.fgColor, 0.34)
                }

                HoverHandler { id: tabHover; cursorShape: Qt.PointingHandCursor }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.activeTab = tabItem.modelData.id
                    bodyFlick.contentY = 0
                  }
                }
              }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: root.hairline
          }
        }

        // ============================================================ SCROLLABLE BODY
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true

          Flickable {
            id: bodyFlick
            anchors.fill: parent
            contentWidth: width
            contentHeight: bodyStack.implicitHeight + Style.space(8)
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: bodyStack
              width: bodyFlick.width
              spacing: Style.space(12)

              SLTabs.GeneralTab {
                visible: root.activeTab === "general"
                width: parent.width
                panel: root
                strings: strings
              }

              SLTabs.ProvidersTab {
                visible: root.activeTab === "providers"
                width: parent.width
                panel: root
                strings: strings
              }

              SLTabs.TasksTab {
                visible: root.activeTab === "tasks"
                width: parent.width
                panel: root
                strings: strings
              }

              SLTabs.ActionsTab {
                visible: root.activeTab === "actions"
                width: parent.width
                panel: root
                strings: strings
              }

              SLTabs.LanguageTab {
                visible: root.activeTab === "language"
                width: parent.width
                panel: root
                strings: strings
              }
            }
          }

          // Floating Reel-style toast card (never shifts layout)
          Rectangle {
            id: toastCard
            z: 20
            visible: root.statusText.length > 0
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            radius: root.cornerRadius
            color: root.bgColor
            border.width: 1
            border.color: root.statusError ? Util.alpha(root.urgentColor, 0.55) : Util.alpha(root.accentColor, 0.45)
            clip: true
            implicitHeight: toastBodyText.implicitHeight + Style.space(18)

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.space(3)
              color: root.statusError ? root.urgentColor : root.accentColor
            }

            PlainText {
              id: toastBodyText
              anchors.left: parent.left
              anchors.right: toastCloseBtn.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(6)
              text: root.statusText
              color: root.statusError ? root.urgentColor : root.fgColor
              font.family: root.uiFont
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Rectangle {
              id: toastCloseBtn
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22)
              height: Style.space(22)
              radius: Math.min(3, root.cornerRadius)
              color: toastCloseHover.hovered ? root.hoverFill : "transparent"

              PlainText {
                anchors.centerIn: parent
                text: "󰅖"
                color: toastCloseHover.hovered ? root.fgColor : root.mutedInk
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
              }

              HoverHandler { id: toastCloseHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  statusClearTimer.stop()
                  root.statusText = ""
                  root.statusError = false
                }
              }
            }
          }
        }

        // ============================================================ FIXED KEYHINT FOOTER
        Item {
          Layout.fillWidth: true
          implicitHeight: Style.space(24)

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: root.hairline
          }

          Row {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            spacing: Style.space(10)

            Row {
              spacing: Style.space(4)
              SLUi.KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "Tab"; fgColor: root.fgColor; cornerRadius: root.cornerRadius; uiFont: root.uiFont }
              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Tabs"
                color: root.mutedInk
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              spacing: Style.space(4)
              SLUi.KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "c"; fgColor: root.fgColor; cornerRadius: root.cornerRadius; uiFont: root.uiFont }
              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Capture"
                color: root.mutedInk
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              spacing: Style.space(4)
              SLUi.KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "Esc"; fgColor: root.fgColor; cornerRadius: root.cornerRadius; uiFont: root.uiFont }
              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Close"
                color: root.mutedInk
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
              }
            }
          }

          Row {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Style.space(6)

            PlainText {
              anchors.verticalCenter: parent.verticalCenter
              text: "v" + String((root.manifest && root.manifest.version) || "0.9.2")
              color: Util.alpha(root.fgColor, 0.38)
              font.family: root.uiFont
              font.pixelSize: Style.font.caption
            }

            // Reel-inspired compact update cue chip (click to check/update, or Shift+U)
            Rectangle {
              id: updateChip
              anchors.verticalCenter: parent.verticalCenter
              radius: Math.min(3, root.cornerRadius)
              clip: true
              color: root.updateAvailable
                ? (updateHover.hovered ? Util.alpha(root.accentColor, 0.24) : Util.alpha(root.accentColor, 0.14))
                : (root.updateError
                    ? Util.alpha(root.urgentColor, 0.16)
                    : (updateHover.hovered ? root.hoverFill : "transparent"))
              border.width: 1
              border.color: root.updateAvailable
                ? (updateHover.hovered ? root.accentColor : Util.alpha(root.accentColor, 0.48))
                : (root.updateError
                    ? Util.alpha(root.urgentColor, 0.48)
                    : (updateHover.hovered ? Util.alpha(root.fgColor, 0.28) : Util.alpha(root.fgColor, 0.10)))
              implicitWidth: Math.max(Style.space(22), updateChipRow.implicitWidth + Style.space(10))
              implicitHeight: Style.space(17)

              Row {
                id: updateChipRow
                anchors.centerIn: parent
                spacing: Style.space(3)

                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.updateAvailable ? "↑" : "󰑐"
                  color: root.updateAvailable
                    ? root.accentColor
                    : (root.updateError
                        ? root.urgentColor
                        : (root.updateChecking || updateHover.hovered ? root.secondaryInk : Util.alpha(root.fgColor, 0.40)))
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                  font.bold: root.updateAvailable
                }

                PlainText {
                  visible: root.updateAvailable && root.updateBehind > 0
                  anchors.verticalCenter: parent.verticalCenter
                  text: Commons.I18n.formatNumber(root.updateBehind)
                  color: root.accentColor
                  font.family: root.uiFont
                  font.pixelSize: Math.max(9, Style.font.caption - 1)
                  font.bold: true
                }
              }

              // Sweeping 2 px accent progress bar while checking
              Rectangle {
                visible: root.updateChecking
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 2
                color: Util.alpha(root.accentColor, 0.18)

                Rectangle {
                  readonly property real trackW: parent.width
                  readonly property real barW: Math.max(8, trackW * 0.45)
                  readonly property real phase: ((root.updateSweepTick * 0.08) % 1.0)
                  x: -barW + phase * (trackW + barW)
                  width: barW
                  height: parent.height
                  color: root.accentColor
                }
              }

              Ui.PanelToolTip {
                visible: updateHover.hovered
                text: root.updateTooltipText()
              }

              HoverHandler { id: updateHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.updateAvailable) root.applyUpdate()
                  else root.checkForUpdates(true)
                }
              }
            }
          }
        }
      }
    }
  }
}
