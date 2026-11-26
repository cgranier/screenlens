import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "ScreenLensLogic.js" as Logic

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

  property string activeTab: "general" // "general" | "providers" | "tasks" | "language"
  readonly property var tabIds: ["general", "providers", "tasks", "language"]

  // Live config state loaded from 0600 ~/.config/omarchy/screenlens.json
  property var config: ({})
  property var catalog: ({})
  property string omarchyDefaultAgent: ""
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

  // Language & OCR tab state
  property string customTranslateLangDraft: ""
  property var ocrInstalled: []
  property var ocrAvailable: []
  property string selectedOcrInstallCode: ""
  property bool installingOcrPack: false

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
    Util.execArgv(["omarchy-shell", "shell", "summon", root.moduleName, "{}"])
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
          root.omarchyDefaultAgent = String(res.defaultAgent || "")
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

  // ---------------------------------------------------------------- inline UI helpers

  // Custom crisp ScreenLens vector mark (4 rounded viewfinder brackets + center lens dot)
  // drawn on a 24-unit coordinate space via Shape.CurveRenderer for sharp DPI scaling.
  component LensMark: Shape {
    id: mark
    property real iconSize: Style.bar.iconCanvas
    property color inkColor: root.barForeground
    property color dotColor: inkColor
    readonly property real u: iconSize / 24.0
    width: iconSize
    height: iconSize
    implicitWidth: iconSize
    implicitHeight: iconSize
    preferredRendererType: Shape.CurveRenderer
    antialiasing: true

    // Top-left bracket
    ShapePath {
      fillColor: "transparent"
      strokeColor: Util.alpha(mark.inkColor, 0.92)
      strokeWidth: Math.max(1.4, 2.2 * mark.u)
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      startX: 3.5 * mark.u; startY: 8.5 * mark.u
      PathLine { x: 3.5 * mark.u; y: 5.5 * mark.u }
      PathQuad { x: 5.5 * mark.u; y: 3.5 * mark.u; controlX: 3.5 * mark.u; controlY: 3.5 * mark.u }
      PathLine { x: 8.5 * mark.u; y: 3.5 * mark.u }
    }
    // Top-right bracket
    ShapePath {
      fillColor: "transparent"
      strokeColor: Util.alpha(mark.inkColor, 0.92)
      strokeWidth: Math.max(1.4, 2.2 * mark.u)
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      startX: 15.5 * mark.u; startY: 3.5 * mark.u
      PathLine { x: 18.5 * mark.u; y: 3.5 * mark.u }
      PathQuad { x: 20.5 * mark.u; y: 5.5 * mark.u; controlX: 20.5 * mark.u; controlY: 3.5 * mark.u }
      PathLine { x: 20.5 * mark.u; y: 8.5 * mark.u }
    }
    // Bottom-left bracket
    ShapePath {
      fillColor: "transparent"
      strokeColor: Util.alpha(mark.inkColor, 0.92)
      strokeWidth: Math.max(1.4, 2.2 * mark.u)
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      startX: 3.5 * mark.u; startY: 15.5 * mark.u
      PathLine { x: 3.5 * mark.u; y: 18.5 * mark.u }
      PathQuad { x: 5.5 * mark.u; y: 20.5 * mark.u; controlX: 3.5 * mark.u; controlY: 20.5 * mark.u }
      PathLine { x: 8.5 * mark.u; y: 20.5 * mark.u }
    }
    // Bottom-right bracket
    ShapePath {
      fillColor: "transparent"
      strokeColor: Util.alpha(mark.inkColor, 0.92)
      strokeWidth: Math.max(1.4, 2.2 * mark.u)
      capStyle: ShapePath.RoundCap
      joinStyle: ShapePath.RoundJoin
      startX: 15.5 * mark.u; startY: 20.5 * mark.u
      PathLine { x: 18.5 * mark.u; y: 20.5 * mark.u }
      PathQuad { x: 20.5 * mark.u; y: 18.5 * mark.u; controlX: 20.5 * mark.u; controlY: 20.5 * mark.u }
      PathLine { x: 20.5 * mark.u; y: 15.5 * mark.u }
    }
    // Center lens circle
    ShapePath {
      fillColor: mark.dotColor
      strokeColor: "transparent"
      strokeWidth: 0
      PathAngleArc {
        centerX: 12 * mark.u
        centerY: 12 * mark.u
        radiusX: 3.2 * mark.u
        radiusY: 3.2 * mark.u
        startAngle: 0
        sweepAngle: 360
      }
    }
  }

  component SectionLabel: PlainText {
    color: root.mutedInk
    font.family: root.uiFont
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.0
    leftPadding: Style.space(2)
  }

  component SectionCard: Rectangle {
    radius: root.cornerRadius
    color: root.cardFill
    border.width: 1
    border.color: root.cardBorder
    clip: true
  }

  component CardDivider: Rectangle {
    height: 1
    color: root.rowDivider
  }

  component KeyCap: Rectangle {
    id: kcap
    property string label: ""
    property color capTextColor: Util.alpha(root.fgColor, 0.72)
    property color capBg: Util.alpha(root.fgColor, 0.06)
    property color capBorder: Util.alpha(root.fgColor, 0.16)
    radius: Math.min(3, root.cornerRadius)
    color: capBg
    border.width: 1
    border.color: capBorder
    implicitWidth: kcapTxt.implicitWidth + Style.space(8)
    implicitHeight: kcapTxt.implicitHeight + Style.space(3)

    PlainText {
      id: kcapTxt
      anchors.centerIn: parent
      text: kcap.label
      color: kcap.capTextColor
      font.family: root.uiFont
      font.pixelSize: Math.max(9, Style.font.caption - 1)
    }
  }

  component PillOption: Rectangle {
    id: pill
    property string label: ""
    property string icon: ""
    property bool active: false
    property bool showDot: false
    property bool dotReady: false
    property real fontSize: Style.font.bodySmall
    signal clicked()

    radius: Math.min(4, root.cornerRadius)
    color: active
      ? Util.alpha(root.accentColor, 0.18)
      : (pillHover.hovered ? root.hoverFill : root.restFill)
    border.width: 1
    border.color: active
      ? Util.alpha(root.accentColor, 0.65)
      : (pillHover.hovered ? Util.alpha(root.fgColor, 0.22) : root.cardBorder)
    implicitWidth: pillRow.implicitWidth + Style.space(16)
    implicitHeight: Style.space(26)

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.space(5)

      Rectangle {
        visible: pill.showDot
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(6)
        height: Style.space(6)
        radius: width / 2
        color: pill.dotReady ? root.accentColor : "transparent"
        border.width: pill.dotReady ? 0 : 1
        border.color: root.mutedInk
      }

      PlainText {
        visible: pill.icon.length > 0
        anchors.verticalCenter: parent.verticalCenter
        text: pill.icon
        color: pill.active ? root.accentColor : root.secondaryInk
        font.family: root.uiFont
        font.pixelSize: pill.fontSize
      }

      PlainText {
        anchors.verticalCenter: parent.verticalCenter
        text: pill.label
        color: pill.active ? root.fgColor : root.secondaryInk
        font.family: root.uiFont
        font.pixelSize: pill.fontSize
        font.bold: pill.active
      }
    }

    HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.clicked()
    }
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
      LensMark {
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

            LensMark {
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

                KeyCap {
                  anchors.verticalCenter: parent.verticalCenter
                  label: "c"
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
                { id: "language",  icon: "󰗊", label: strings.t("settings.tab.language") }
              ]
              delegate: Item {
                id: tabItem
                required property var modelData
                readonly property bool isActive: root.activeTab === modelData.id
                width: tabStripRow.width / 4
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

              // ------------------------------------------------------ GENERAL TAB
              Column {
                visible: root.activeTab === "general"
                width: parent.width
                spacing: Style.space(10)

                SectionLabel { text: strings.t("settings.section.keybind").toUpperCase() }

                SectionCard {
                  width: parent.width
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
                          foreground: root.fgColor
                          anchors.verticalCenter: parent.verticalCenter
                          text: strings.t("settings.apply")
                          fontSize: Style.font.bodySmall
                          bordered: true
                          selected: true
                          onClicked: root.applyKeybind()
                        }
                      }
                    }

                    CardDivider { width: parent.width }

                    Item {
                      width: parent.width
                      implicitHeight: Math.max(Style.space(38), rebindLabel.implicitHeight + Style.space(14))

                      PlainText {
                        id: rebindLabel
                        anchors.left: parent.left
                        anchors.right: rebindSwitch.left
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        text: strings.t("settings.rebindHint")
                        color: root.secondaryInk
                        font.family: root.uiFont
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.Wrap
                      }

                      Ui.ToggleSwitch {
                        id: rebindSwitch
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        checked: root.rebindExisting
                        foreground: root.fgColor
                        accent: root.accentColor
                        onToggled: root.rebindExisting = !root.rebindExisting
                      }
                    }
                  }
                }

                SectionLabel { text: strings.t("settings.section.appearance").toUpperCase() }

                SectionCard {
                  width: parent.width
                  implicitHeight: Style.space(42)

                  PlainText {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    text: strings.t("settings.section.appearance")
                    color: root.fgColor
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                  }

                  Row {
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)

                    Repeater {
                      model: [
                        { id: "system", label: strings.t("settings.theme.system") },
                        { id: "dark",   label: strings.t("settings.theme.dark") },
                        { id: "light",  label: strings.t("settings.theme.light") }
                      ]
                      delegate: PillOption {
                        required property var modelData
                        label: modelData.label
                        active: root.cfgVal("theme", "system") === modelData.id
                        onClicked: root.patchConfig({ theme: modelData.id })
                      }
                    }
                  }
                }

                SectionLabel { text: strings.t("settings.section.capture").toUpperCase() }

                SectionCard {
                  width: parent.width
                  implicitHeight: captureCardCol.implicitHeight

                  Column {
                    id: captureCardCol
                    width: parent.width

                    Item {
                      width: parent.width
                      implicitHeight: Style.space(42)

                      PlainText {
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        text: strings.t("settings.section.capture")
                        color: root.fgColor
                        font.family: root.uiFont
                        font.pixelSize: Style.font.bodySmall
                      }

                      Row {
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(4)

                        PillOption {
                          icon: "󰒅"
                          label: strings.t("mode.lasso")
                          active: root.cfgVal("defaultMode", "lasso") === "lasso"
                          onClicked: root.patchConfig({ defaultMode: "lasso" })
                        }

                        PillOption {
                          icon: "󰗧"
                          label: strings.t("mode.text")
                          active: root.cfgVal("defaultMode", "lasso") === "text"
                          onClicked: root.patchConfig({ defaultMode: "text" })
                        }
                      }
                    }

                    CardDivider { width: parent.width }

                    Item {
                      width: parent.width
                      implicitHeight: Style.space(42)

                      PlainText {
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        text: strings.t("settings.maxImageDim")
                        color: root.fgColor
                        font.family: root.uiFont
                        font.pixelSize: Style.font.bodySmall
                      }

                      Row {
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(4)

                        Repeater {
                          model: [1280, 1920, 2560, 3840]
                          delegate: PillOption {
                            required property int modelData
                            label: String(modelData) + "px"
                            fontSize: Style.font.caption
                            active: Number(root.cfgVal("maxImageDim", 1920)) === modelData
                            onClicked: root.patchConfig({ maxImageDim: modelData })
                          }
                        }
                      }
                    }
                  }
                }
              }

              // ------------------------------------------------------ PROVIDERS TAB
              Column {
                visible: root.activeTab === "providers"
                width: parent.width
                spacing: Style.space(10)

                SectionLabel { text: strings.t("settings.defaultProvider").toUpperCase() }

                SectionCard {
                  width: parent.width
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
                      delegate: PillOption {
                        required property var modelData
                        label: modelData.label
                        active: root.cfgVal("defaultProvider", "auto") === modelData.id
                        onClicked: root.patchConfig({ defaultProvider: modelData.id })
                      }
                    }
                  }
                }

                SectionLabel { text: strings.t("settings.configuredProviders").toUpperCase() }

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
                    delegate: PillOption {
                      required property var modelData
                      label: modelData.label
                      fontSize: Style.font.caption
                      showDot: true
                      dotReady: root.providerReady(modelData.id)
                      active: root.selectedProvider === modelData.id
                      onClicked: root.selectProvider(modelData.id)
                    }
                  }
                }

                // Active provider detail editor card
                SectionCard {
                  width: parent.width
                  border.color: Util.alpha(root.accentColor, 0.32)
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

                        PlainText {
                          text: String(root.currentProviderMeta().name || root.selectedProvider)
                          color: root.fgColor
                          font.family: root.uiFont
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
                            color: root.providerReady(root.selectedProvider) ? root.accentColor : "transparent"
                            border.width: root.providerReady(root.selectedProvider) ? 0 : 1
                            border.color: root.mutedInk
                          }

                          PlainText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.providerStatusBadge(root.selectedProvider)
                            color: root.providerReady(root.selectedProvider) ? root.accentColor : root.mutedInk
                            font.family: root.uiFont
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
                          foreground: root.fgColor
                          visible: String(root.currentProviderMeta().keyUrl || "").length > 0
                          text: strings.t("settings.getApiKey")
                          fontSize: Style.font.caption
                          bordered: true
                          onClicked: root.openKeyConsole(root.selectedProvider)
                        }

                        Ui.Button {
                          foreground: root.fgColor
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

                    // Inline test result pill
                    Rectangle {
                      visible: root.providerTestText.length > 0
                      width: parent.width
                      radius: Math.min(3, root.cornerRadius)
                      color: root.providerTestOk ? Util.alpha(root.accentColor, 0.12) : Util.alpha(root.urgentColor, 0.14)
                      border.width: 1
                      border.color: root.providerTestOk ? Util.alpha(root.accentColor, 0.36) : Util.alpha(root.urgentColor, 0.45)
                      implicitHeight: provTestLabel.implicitHeight + Style.space(10)

                      PlainText {
                        id: provTestLabel
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(8)
                        text: root.providerTestText
                        color: root.providerTestOk ? root.accentColor : root.urgentColor
                        font.family: root.uiFont
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        wrapMode: Text.Wrap
                      }
                    }

                    CardDivider { width: parent.width }

                    // Model dropdown + refresh button
                    Row {
                      id: modelRow
                      width: parent.width
                      spacing: Style.space(6)

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
                        foreground: root.fgColor
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
                      spacing: Style.space(6)

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
                        foreground: root.fgColor
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
                      spacing: Style.space(5)

                      CardDivider { width: parent.width }

                      PlainText {
                        text: strings.t("settings.apiKeyLabel")
                        color: root.secondaryInk
                        font.family: root.uiFont
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
                          foreground: root.fgColor
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
                          foreground: root.fgColor
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
                      spacing: Style.space(5)

                      CardDivider { width: parent.width }

                      PlainText {
                        text: strings.t("settings.ollamaHostLabel")
                        color: root.secondaryInk
                        font.family: root.uiFont
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      Row {
                        id: ollamaRow
                        width: parent.width
                        spacing: Style.space(6)

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
                          foreground: root.fgColor
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
                      spacing: Style.space(5)

                      CardDivider { width: parent.width }

                      PlainText {
                        text: strings.t("settings.cliAgentLabel")
                        color: root.secondaryInk
                        font.family: root.uiFont
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      Flow {
                        width: parent.width
                        spacing: Style.space(5)

                        Repeater {
                          model: Array.isArray(root.currentProviderMeta().clis)
                            ? root.currentProviderMeta().clis
                            : ["default", "claude", "codex", "agy", "opencode", "grok", "gemini"]
                          delegate: PillOption {
                            required property string modelData
                            label: modelData
                            fontSize: Style.font.caption
                            active: String(root.currentProviderCfg().cli || "default") === modelData
                            onClicked: root.selectAgentCli(modelData)
                          }
                        }
                      }
                    }
                  }
                }
              }

              // ------------------------------------------------------ TASKS TAB
              Column {
                id: tasksTabCol
                visible: root.activeTab === "tasks"
                width: parent.width
                spacing: Style.space(10)
                readonly property bool taskRoutingOn: !!(root.config && root.config.taskRouting && root.config.taskRouting.enabled)

                SectionLabel { text: "PER-TASK ROUTING" }

                SectionCard {
                  width: parent.width
                  implicitHeight: routingCardCol.implicitHeight

                  Column {
                    id: routingCardCol
                    width: parent.width

                    Item {
                      width: parent.width
                      implicitHeight: Style.space(40)

                      PlainText {
                        id: routingLabel
                        anchors.left: parent.left
                        anchors.right: routingSwitch.left
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(10)
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
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        checked: tasksTabCol.taskRoutingOn
                        foreground: root.fgColor
                        accent: root.accentColor
                        onToggled: root.patchConfig({
                          taskRouting: { enabled: !tasksTabCol.taskRoutingOn }
                        })
                      }
                    }

                    Repeater {
                      model: [
                        { key: "general",   label: strings.t("settings.task.general") },
                        { key: "vision",    label: strings.t("settings.task.vision") },
                        { key: "text",      label: strings.t("settings.task.text") },
                        { key: "translate", label: strings.t("settings.task.translate") }
                      ]
                      delegate: Column {
                        required property var modelData
                        width: routingCardCol.width
                        opacity: tasksTabCol.taskRoutingOn ? 1.0 : 0.42
                        enabled: tasksTabCol.taskRoutingOn

                        CardDivider { width: parent.width }

                        Column {
                          width: parent.width - Style.space(20)
                          x: Style.space(10)
                          topPadding: Style.space(8)
                          bottomPadding: Style.space(8)
                          spacing: Style.space(5)

                          PlainText {
                            text: modelData.label
                            color: root.secondaryInk
                            font.family: root.uiFont
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
                              value: root.taskProviderValue(modelData.key)
                              options: [
                                { value: "", label: strings.t("settings.useDefault") },
                                { value: "auto", label: "Auto" },
                                { value: "gemini", label: "Gemini" },
                                { value: "anthropic", label: "Claude" },
                                { value: "openai", label: "OpenAI" },
                                { value: "ollama", label: "Ollama" },
                                { value: "agent", label: "CLI Agent" }
                              ]
                              foreground: root.fgColor
                              background: root.bgColor
                              accent: root.accentColor
                              onChanged: function(nextProv) {
                                root.saveTaskRouting(modelData.key, { provider: nextProv, model: "" })
                              }
                            }

                            Ui.Dropdown {
                              width: (taskPickRow.width - taskPickRow.spacing) * 0.58
                              showLabel: false
                              value: root.taskModelValue(modelData.key)
                              options: root.taskModelOptions(modelData.key)
                              foreground: root.fgColor
                              background: root.bgColor
                              accent: root.accentColor
                              onChanged: function(nextMod) {
                                root.saveTaskRouting(modelData.key, { model: nextMod })
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }

                SectionLabel { text: strings.t("settings.task.handoff").toUpperCase() }

                SectionCard {
                  width: parent.width
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
                      value: String((root.config && root.config.taskRouting && root.config.taskRouting.handoffAgent) || "default")
                      options: [
                        { value: "default", label: strings.t("settings.handoffDefault") },
                        { value: "claude", label: "claude" },
                        { value: "codex", label: "codex" },
                        { value: "agy", label: "agy" },
                        { value: "opencode", label: "opencode" },
                        { value: "grok", label: "grok" },
                        { value: "gemini", label: "gemini" }
                      ]
                      foreground: root.fgColor
                      background: root.bgColor
                      accent: root.accentColor
                      onChanged: function(nextCli) {
                        root.patchConfig({ taskRouting: { handoffAgent: nextCli } })
                      }
                    }
                  }
                }
              }

              // ------------------------------------------------------ LANGUAGE & OCR TAB
              Column {
                visible: root.activeTab === "language"
                width: parent.width
                spacing: Style.space(10)

                SectionLabel { text: strings.t("settings.translateLanguage").toUpperCase() }

                SectionCard {
                  width: parent.width
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
                          delegate: PillOption {
                            required property string modelData
                            label: modelData
                            active: root.cfgVal("translateLanguage", "English") === modelData
                            onClicked: root.patchConfig({ translateLanguage: modelData })
                          }
                        }
                      }
                    }

                    CardDivider { width: parent.width }

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
                          text: root.customTranslateLangDraft
                          placeholderText: strings.t("settings.customLangPlaceholder")
                          foreground: root.fgColor
                          accent: root.accentColor
                          onTextEdited: root.customTranslateLangDraft = text
                          onAccepted: {
                            var lang = root.customTranslateLangDraft.trim()
                            if (lang) {
                              root.patchConfig({ translateLanguage: lang })
                              root.customTranslateLangDraft = ""
                            }
                          }
                          Keys.onEscapePressed: root.close()
                        }

                        Ui.Button {
                          id: saveCustomLangBtn
                          foreground: root.fgColor
                          anchors.verticalCenter: parent.verticalCenter
                          text: strings.t("settings.save")
                          fontSize: Style.font.caption
                          bordered: true
                          onClicked: {
                            var lang = root.customTranslateLangDraft.trim()
                            if (lang) {
                              root.patchConfig({ translateLanguage: lang })
                              root.customTranslateLangDraft = ""
                            }
                          }
                        }
                      }
                    }
                  }
                }

                SectionLabel { text: strings.t("settings.ocrLanguages").toUpperCase() }

                SectionCard {
                  width: parent.width
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

                      PlainText {
                        width: parent.width
                        text: strings.t("settings.ocrToggleHint")
                        color: root.secondaryInk
                        font.family: root.uiFont
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.Wrap
                      }

                      Flow {
                        width: parent.width
                        spacing: Style.space(5)

                        Repeater {
                          model: root.ocrInstalled
                          delegate: PillOption {
                            required property var modelData
                            label: modelData.name + " (" + modelData.code + ")"
                            icon: root.isOcrLangActive(modelData.code) ? "󰄬" : ""
                            active: root.isOcrLangActive(modelData.code)
                            onClicked: root.toggleOcrLang(modelData.code)
                          }
                        }
                      }
                    }

                    CardDivider {
                      visible: root.ocrAvailable.length > 0
                      width: parent.width
                    }

                    Column {
                      visible: root.ocrAvailable.length > 0
                      width: parent.width - Style.space(16)
                      x: Style.space(8)
                      topPadding: Style.space(8)
                      bottomPadding: Style.space(8)
                      spacing: Style.space(6)

                      PlainText {
                        text: strings.t("settings.ocrDownloadSection")
                        color: root.secondaryInk
                        font.family: root.uiFont
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
                          value: root.selectedOcrInstallCode
                          options: root.ocrAvailableOptions()
                          foreground: root.fgColor
                          background: root.bgColor
                          accent: root.accentColor
                          onChanged: function(nextCode) {
                            root.selectedOcrInstallCode = nextCode
                          }
                        }

                        Ui.Button {
                          id: ocrInstallBtn
                          foreground: root.fgColor
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.installingOcrPack ? strings.t("settings.installing") : strings.t("settings.installPack")
                          iconText: "󰇚"
                          iconSpinning: root.installingOcrPack
                          fontSize: Style.font.caption
                          bordered: true
                          selected: true
                          onClicked: root.installSelectedOcrPack()
                        }
                      }

                      PlainText {
                        visible: root.selectedOcrInstallCode.length > 0
                        width: parent.width
                        text: strings.t("settings.ocrCliHint").arg("omarchy pkg add tesseract-data-" + root.selectedOcrInstallCode)
                        color: root.mutedInk
                        font.family: root.uiFont
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.Wrap
                      }
                    }
                  }
                }
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
              KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "Tab" }
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
              KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "c" }
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
              KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "Esc" }
              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Close"
                color: root.mutedInk
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
              }
            }
          }

          PlainText {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: "v" + String((root.manifest && root.manifest.version) || "0.9.0")
            color: Util.alpha(root.fgColor, 0.38)
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
