import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "ScreenLensLogic.js" as Logic
import "ui" as SLUi

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")

  property bool opened: false
  property bool capturing: false

  // Captured frame & active window metadata
  property string screenshotPath: ""
  property int imageWidth: 0
  property int imageHeight: 0
  property string windowClass: ""
  property string windowTitle: ""

  // Interaction mode: "lasso" (freehand circle), "box" (rectangle marquee), or "text" (OCR word selection)
  property string mode: "lasso"
  readonly property bool isRegionMode: mode === "lasso" || mode === "box"
  property var lassoPoints: []
  property var lassoPathPoints: [] // Array of Qt.point() for PathPolyline
  property var boxStartPoint: null
  property var boxPreviewRect: null
  property bool draggingCanvas: false
  readonly property int maxPinnedRegions: 6
  property var selectionRects: [] // Array of logical {x, y, w, h} rects
  property int activeRegionIndex: -1
  readonly property var selectionRect: {
    if (!Array.isArray(selectionRects) || selectionRects.length === 0) return null
    var idx = (activeRegionIndex >= 0 && activeRegionIndex < selectionRects.length)
      ? activeRegionIndex
      : (selectionRects.length - 1)
    return selectionRects[idx]
  }
  property int hoverRegionIndex: -1
  property string hoverHandle: ""
  property int dragRegionIndex: -1
  property string dragHandle: ""
  property var dragStartRect: null
  property real dragStartX: 0
  property real dragStartY: 0
  property bool lassoPinMode: false
  property bool shiftKeyHeld: false

  // OCR state
  property bool ocrLoading: false
  property var rawOcrWords: []
  property var ocrWords: [] // Mapped to logical overlay coordinates
  property int textDragStartIdx: -1
  property var textDragStartPoint: null
  property var selectedWordIndices: []
  property var selectedWordMap: ({})
  property string selectedText: ""
  property var selectedTextBounds: null

  // AI chat & streaming state
  property var messages: [] // [{role: "user"|"assistant", text: "..."}]
  property bool streaming: false
  property string streamingText: ""
  property string providerLabel: ""
  property bool webSearchEnabled: false
  property bool answerUsedWebSearch: false
  property string errorMessage: ""
  property string toastMessage: ""
  property int loadingTick: 0
  property real loadingElapsedSec: 0
  readonly property var spinnerFrames: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  // Superwhisper voice state: "idle" | "recording" | "transcribing"
  property string voiceState: "idle"
  property string voiceBaseline: ""
  property string voicePromptBefore: ""
  property string voiceExpectedAfterInsert: ""
  property string voiceLastTranscript: ""
  property int voiceTick: 0

  // Pending stdin payloads / queued commands for Process helpers
  property string pendingAskJson: ""
  property string pendingHandoffJson: ""
  property bool extractCancelled: false
  property var pendingExtractCommand: null

  // User config loaded from 0600 ~/.config/omarchy/screenlens.json on open
  property var userConfig: ({})
  property string themeMode: "system"

  // Surface tokens aligned with Omarchy's menu & popup surfaces, with optional
  // Dark / Light surface override while preserving the live Omarchy accent.
  readonly property var resolvedPalette: Logic.resolveThemePalette(root.themeMode, {
    background: Commons.Color.menu.background,
    text: Commons.Color.menu.text,
    border: Commons.Color.menu.border,
    scrim: Commons.Color.menu.scrim,
    accent: Commons.Color.accent,
    urgent: Commons.Color.urgent
  })
  readonly property color bgColor: resolvedPalette.background
  readonly property color fgColor: resolvedPalette.text
  readonly property color accentColor: resolvedPalette.accent
  readonly property color urgentColor: resolvedPalette.urgent
  readonly property color borderColor: resolvedPalette.border
  readonly property color scrimColor: resolvedPalette.scrim
  readonly property color onAccentInk: Logic.inkOn(String(accentColor))
  readonly property color restFill: Util.alpha(fgColor, 0.05)
  readonly property color hoverFill: Util.alpha(fgColor, 0.10)
  readonly property color hairlineColor: Util.alpha(fgColor, 0.14)
  readonly property color mutedInk: Util.alpha(fgColor, 0.56)
  readonly property var cardBorderSpec: root.themeMode === "system"
    ? Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
    : Border.flat(borderColor, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string uiFont: Style.font.menuFamily

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  // ---------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    if (root.opened) {
      root.dismiss()
      return
    }
    if (root.capturing) return

    root.resetSession()
    root.capturing = true
    loadCfgProc.running = false
    loadCfgProc.running = true
    captureProc.running = false
    captureProc.running = true
  }

  function close() {
    root.stopBackgroundWork()
    root.shiftKeyHeld = false
    root.opened = false
    root.capturing = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") {
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.cgranier.screenlens")
    }
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function resetSession() {
    root.stopBackgroundWork()
    root.screenshotPath = ""
    root.imageWidth = 0
    root.imageHeight = 0
    root.windowClass = ""
    root.windowTitle = ""
    root.mode = "lasso"
    root.lassoPoints = []
    root.lassoPathPoints = []
    root.boxStartPoint = null
    root.boxPreviewRect = null
    root.draggingCanvas = false
    root.selectionRects = []
    root.activeRegionIndex = -1
    root.hoverRegionIndex = -1
    root.hoverHandle = ""
    root.dragRegionIndex = -1
    root.dragHandle = ""
    root.dragStartRect = null
    root.lassoPinMode = false
    root.shiftKeyHeld = false
    root.ocrLoading = false
    root.rawOcrWords = []
    root.ocrWords = []
    root.textDragStartIdx = -1
    root.textDragStartPoint = null
    root.selectedWordIndices = []
    root.selectedWordMap = ({})
    root.selectedText = ""
    root.selectedTextBounds = null
    root.messages = []
    root.streaming = false
    root.streamingText = ""
    root.providerLabel = ""
    root.webSearchEnabled = false
    root.answerUsedWebSearch = false
    root.errorMessage = ""
    root.toastMessage = ""
    root.voiceState = "idle"
    root.voiceBaseline = ""
    root.voicePromptBefore = ""
    root.voiceExpectedAfterInsert = ""
    root.voiceLastTranscript = ""
    voiceDedupeTimer.stop()
    promptField.text = ""
  }

  function stopBackgroundWork() {
    if (askProc.running) askProc.running = false
    if (ocrProc.running) ocrProc.running = false
    root.pendingExtractCommand = null
    if (extractProc.running) {
      root.extractCancelled = true
      extractProc.running = false
    }
    if (root.voiceState === "recording") {
      root.voiceState = "idle"
      Quickshell.execDetached(["/usr/bin/python3", root.pluginDir + "/scripts/voice.py", "cancel"])
    }
    root.streaming = false
  }

  function showToast(msg) {
    root.toastMessage = String(msg || "")
    toastTimer.restart()
  }

  function setSelectedWords(indices, text, bounds) {
    var map = ({})
    if (Array.isArray(indices)) {
      for (var i = 0; i < indices.length; i++) map[indices[i]] = true
    }
    root.selectedWordIndices = indices || []
    root.selectedWordMap = map
    root.selectedText = text || ""
    root.selectedTextBounds = bounds || null
  }

  function clearSelection() {
    root.lassoPoints = []
    root.lassoPathPoints = []
    root.boxStartPoint = null
    root.boxPreviewRect = null
    root.selectionRects = []
    root.activeRegionIndex = -1
    root.hoverRegionIndex = -1
    root.hoverHandle = ""
    root.dragRegionIndex = -1
    root.dragHandle = ""
    root.dragStartRect = null
    root.lassoPinMode = false
    root.setSelectedWords([], "", null)
  }

  function setMode(nextMode) {
    if (nextMode !== "lasso" && nextMode !== "box" && nextMode !== "text") return
    root.draggingCanvas = false
    root.dragRegionIndex = -1
    root.dragHandle = ""
    root.dragStartRect = null
    root.hoverRegionIndex = -1
    root.hoverHandle = ""
    root.lassoPoints = []
    root.lassoPathPoints = []
    root.boxStartPoint = null
    root.boxPreviewRect = null
    root.lassoPinMode = false
    root.mode = nextMode
    promptField.forceActiveFocus()
  }

  function cycleMode(delta) {
    var order = ["lasso", "box", "text"]
    var idx = order.indexOf(root.mode)
    if (idx < 0) idx = 0
    root.setMode(order[(idx + delta + order.length) % order.length])
  }

  function removeRegion(idx) {
    if (!Array.isArray(root.selectionRects) || idx < 0 || idx >= root.selectionRects.length) return
    var next = root.selectionRects.slice()
    next.splice(idx, 1)
    root.selectionRects = next
    root.activeRegionIndex = next.length > 0 ? Math.min(idx, next.length - 1) : -1
    root.hoverRegionIndex = -1
    root.hoverHandle = ""
    root.setSelectedWords([], "", null)
    promptField.forceActiveFocus()
  }

  function cursorForHandle(handle) {
    if (handle === "nw" || handle === "se") return Qt.SizeFDiagCursor
    if (handle === "ne" || handle === "sw") return Qt.SizeBDiagCursor
    if (handle === "n" || handle === "s") return Qt.SizeVerCursor
    if (handle === "e" || handle === "w") return Qt.SizeHorCursor
    if (handle === "move") return root.draggingCanvas ? Qt.ClosedHandCursor : Qt.OpenHandCursor
    return Qt.CrossCursor
  }

  function remapOcrWords() {
    root.ocrWords = Logic.mapWordsToOverlay(
      root.rawOcrWords,
      root.imageWidth,
      root.imageHeight,
      panel.width,
      panel.height
    )
  }

  function currentImageCrop() {
    if (!root.selectionRect) return null
    return Logic.logicalToImageRect(
      root.selectionRect,
      panel.width,
      panel.height,
      root.imageWidth,
      root.imageHeight
    )
  }

  function currentImageCrops() {
    if (!Array.isArray(root.selectionRects) || root.selectionRects.length === 0) return []
    var out = []
    for (var i = 0; i < root.selectionRects.length; i++) {
      var mapped = Logic.logicalToImageRect(
        root.selectionRects[i],
        panel.width,
        panel.height,
        root.imageWidth,
        root.imageHeight
      )
      if (mapped) out.push(mapped)
    }
    return out
  }

  // ---------------------------------------------------------------- actions

  function inferTask(explicitTask) {
    if (explicitTask) return explicitTask
    if (root.selectedText && !root.selectionRect) return "text"
    if (root.selectionRect) return "vision"
    return "general"
  }

  function submitPrompt(overridePrompt, explicitTask) {
    var text = String(overridePrompt !== undefined ? overridePrompt : promptField.text).trim()
    if (!text) return
    if (root.streaming) {
      root.cancelStreaming()
    }

    var history = root.messages.slice()
    var nextMessages = root.messages.slice()
    nextMessages.push({ role: "user", text: text })
    root.messages = nextMessages
    if (overridePrompt === undefined) promptField.text = ""

    root.errorMessage = ""
    root.streamingText = ""
    root.answerUsedWebSearch = false
    root.loadingTick = 0
    root.loadingElapsedSec = 0
    root.streaming = true

    var crops = root.currentImageCrops()
    var payload = {
      prompt: text,
      task: root.inferTask(explicitTask),
      imagePath: root.screenshotPath,
      crop: crops.length === 1 ? crops[0] : (crops.length > 1 ? crops[0] : null),
      crops: crops,
      selectedText: root.selectedText,
      windowInfo: { class: root.windowClass, title: root.windowTitle },
      history: history,
      webSearch: root.webSearchEnabled
    }
    root.pendingAskJson = JSON.stringify(payload)
    askProc.running = false
    askProc.running = true
    Qt.callLater(root.scrollAnswersToBottom)
  }

  function cancelStreaming() {
    if (askProc.running) askProc.running = false
    if (root.streamingText.trim().length > 0) {
      var nextMessages = root.messages.slice()
      nextMessages.push({ role: "assistant", text: root.streamingText })
      root.messages = nextMessages
    }
    root.streaming = false
    root.streamingText = ""
  }

  function handleAskEvent(line) {
    var raw = String(line || "").trim()
    if (!raw) return
    var ev = null
    try { ev = JSON.parse(raw) } catch (e) { return }
    if (!ev || !ev.type) return

    if (ev.type === "meta") {
      var prov = String(ev.provider || "")
      var mod = String(ev.model || "")
      root.providerLabel = (prov && mod && prov !== mod) ? (prov + " · " + mod) : (mod || prov)
      root.answerUsedWebSearch = (ev.webSearch === true)
    } else if (ev.type === "delta") {
      root.streamingText += String(ev.text || "")
      Qt.callLater(root.scrollAnswersToBottom)
    } else if (ev.type === "done") {
      if (root.streamingText.length > 0) {
        var nextMessages = root.messages.slice()
        nextMessages.push({ role: "assistant", text: root.streamingText })
        root.messages = nextMessages
      }
      root.streaming = false
      root.streamingText = ""
      Qt.callLater(root.scrollAnswersToBottom)
    } else if (ev.type === "error") {
      root.streaming = false
      root.streamingText = ""
      root.errorMessage = strings.t("error.askFailed").arg(String(ev.message || "unknown error"))
    }
  }

  function runQuickChip(kind) {
    if (kind === "explain") {
      root.submitPrompt("Explain what is shown here clearly and concisely.", root.inferTask(""))
    } else if (kind === "summarize") {
      root.submitPrompt("Summarize the key points shown here in concise bullets.", root.inferTask(""))
    } else if (kind === "translate") {
      var targetLang = (root.userConfig && root.userConfig.translateLanguage)
        ? String(root.userConfig.translateLanguage).trim()
        : "English"
      if (!targetLang) targetLang = "English"
      root.submitPrompt(
        "Translate any visible text here into " + targetLang + ". If it is already in " + targetLang + ", briefly clarify any jargon or idioms.",
        "translate"
      )
    } else if (kind === "extract") {
      root.extractAndCopyText()
    }
  }

  function extractAndCopyText() {
    if (root.selectedText.trim().length > 0) {
      root.copyText(root.selectedText)
      return
    }
    // Instant 0 ms path: reuse words already scanned by background OCR.
    if (!root.ocrLoading && root.ocrWords.length > 0) {
      var cleanInstant = ""
      if (root.selectionRects.length > 1) {
        var chunks = []
        for (var r = 0; r < root.selectionRects.length; r++) {
          var part = Logic.extractWordsInRect(root.ocrWords, root.selectionRects[r])
          if (part && part.text && part.text.trim().length > 0) {
            chunks.push("#" + (r + 1) + "\n" + part.text.trim())
          }
        }
        cleanInstant = chunks.join("\n\n")
      } else {
        var instant = root.selectionRect
          ? Logic.extractWordsInRect(root.ocrWords, root.selectionRect)
          : Logic.selectWordsBetween(root.ocrWords, 0, root.ocrWords.length - 1, null)
        if (instant && instant.text) cleanInstant = instant.text.trim()
      }
      if (cleanInstant.length > 0) {
        root.selectedText = cleanInstant
        root.copyText(cleanInstant)
        return
      }
    }
    if (!root.screenshotPath) return
    root.toastMessage = strings.t("status.extractingText")
    toastTimer.stop()
    var args = ["/usr/bin/python3", root.pluginDir + "/scripts/ocr.py", root.screenshotPath, "--text-only"]
    var crop = root.currentImageCrop()
    if (crop) {
      args.push("--crop")
      args.push(crop.x + "," + crop.y + "," + crop.w + "," + crop.h)
    }
    if (extractProc.running) {
      root.extractCancelled = true
      root.pendingExtractCommand = args
      extractProc.running = false
    } else {
      root.extractCancelled = false
      root.pendingExtractCommand = null
      extractProc.command = args
      extractProc.running = true
    }
  }

  function copyText(text) {
    var s = String(text || "")
    if (!s) return
    // Detach wl-copy directly so dismissing ScreenLens to paste can never
    // tear down the clipboard process before the selection is committed.
    Quickshell.execDetached(["wl-copy", "--", s.slice(0, 65536)])
    root.showToast(strings.t("status.copiedToClipboard"))
  }

  function copySelectedImage() {
    if (!root.screenshotPath) return
    var args = ["/usr/bin/python3", root.pluginDir + "/scripts/actions.py", "copy-image", root.screenshotPath]
    var crop = root.currentImageCrop()
    if (crop) {
      args.push("--crop")
      args.push(crop.x + "," + crop.y + "," + crop.w + "," + crop.h)
    }
    Quickshell.execDetached(args)
    root.showToast(strings.t("status.copiedToClipboard"))
  }

  function latestAssistantText() {
    if (root.streamingText) return root.streamingText
    for (var i = root.messages.length - 1; i >= 0; i--) {
      if (root.messages[i].role === "assistant" && root.messages[i].text) {
        return root.messages[i].text
      }
    }
    return ""
  }

  function copyContextOrAnswer() {
    if (root.selectedText) {
      root.copyText(root.selectedText)
      return
    }
    var ans = root.latestAssistantText()
    if (ans) {
      root.copyText(ans)
      return
    }
    if (root.selectionRect) {
      root.copySelectedImage()
    }
  }

  function handoffToAgent() {
    var allMsgs = root.messages.slice()
    if (root.streamingText.trim().length > 0) {
      allMsgs.push({ role: "assistant", text: root.streamingText })
    }
    var crop = root.currentImageCrop()
    var cropSpec = crop ? (crop.x + "," + crop.y + "," + crop.w + "," + crop.h) : ""
    // Detach directly via Omarchy's login-shell Util.execArgv so tearing down
    // the on-demand overlay can never interrupt the handoff or its terminal.
    Util.execArgv([
      "/usr/bin/python3",
      root.pluginDir + "/scripts/actions.py",
      "handoff-direct",
      "--image", root.screenshotPath,
      "--crop", cropSpec,
      "--window-class", root.windowClass,
      "--window-title", root.windowTitle,
      "--selected-text", root.selectedText,
      "--draft", promptField.text,
      "--messages-json", JSON.stringify(allMsgs)
    ])
    root.dismiss()
  }

  function openSettings() {
    root.dismiss()
    Util.execArgv(["omarchy-shell", "screenlens-settings", "open"])
  }

  function toggleVoice() {
    if (root.voiceState === "transcribing") return
    if (root.voiceState === "idle") {
      root.errorMessage = ""
      root.voicePromptBefore = promptField.text
      root.voiceExpectedAfterInsert = ""
      root.voiceLastTranscript = ""
      voiceDedupeTimer.stop()
      voiceStartProc.running = false
      voiceStartProc.running = true
    } else if (root.voiceState === "recording") {
      root.voiceState = "transcribing"
      voiceStopProc.running = false
      voiceStopProc.command = [
        "/usr/bin/python3",
        root.pluginDir + "/scripts/voice.py",
        "stop",
        "--baseline",
        root.voiceBaseline
      ]
      voiceStopProc.running = true
    }
  }

  function scrollAnswersToBottom() {
    if (answerScroll.contentHeight > answerScroll.height) {
      answerScroll.contentY = answerScroll.contentHeight - answerScroll.height
    }
  }

  function handleEscape() {
    if (root.voiceState === "recording") {
      root.voiceState = "idle"
      Quickshell.execDetached(["/usr/bin/python3", root.pluginDir + "/scripts/voice.py", "cancel"])
      return
    }
    if (root.streaming) {
      root.cancelStreaming()
      return
    }
    if (root.selectionRect || root.selectedText) {
      root.clearSelection()
      return
    }
    root.dismiss()
  }

  function contextBadgeText() {
    if (root.selectedText) {
      var selTpl = strings.t("context.selectedText")
      return selTpl.indexOf("%1") !== -1
        ? selTpl.arg(Commons.I18n.formatNumber(root.selectedText.length))
        : ("Selected text (" + root.selectedText.length + ")")
    }
    if (root.selectionRects.length > 1) {
      var multiTpl = strings.tn("context.multiRegions", root.selectionRects.length)
      return multiTpl.indexOf("%1") !== -1
        ? multiTpl.arg(Commons.I18n.formatNumber(root.selectionRects.length))
        : (root.selectionRects.length + " regions pinned")
    }
    if (root.selectionRect) {
      var crop = root.currentImageCrop()
      var w = crop ? crop.w : Math.round(root.selectionRect.w)
      var h = crop ? crop.h : Math.round(root.selectionRect.h)
      var regTpl = strings.t("context.region")
      return regTpl.indexOf("%1") !== -1
        ? regTpl.arg(Commons.I18n.formatNumber(w)).arg(Commons.I18n.formatNumber(h))
        : ("Region (" + w + "×" + h + ")")
    }
    if (root.windowClass) {
      return strings.t("context.fullScreen") + " · " + root.windowClass
    }
    return strings.t("context.fullScreen")
  }

  // ---------------------------------------------------------------- processes

  Timer {
    id: toastTimer
    interval: 2200
    repeat: false
    onTriggered: root.toastMessage = ""
  }

  Timer {
    id: voiceDedupeTimer
    interval: 800
    repeat: false
    onTriggered: {
      root.voiceExpectedAfterInsert = ""
      root.voiceLastTranscript = ""
    }
  }

  // Drives crisp activity feedback (braille spinner, progress bar, elapsed seconds)
  // even when compositor animations are turned off (`Style.reduceMotion`).
  Timer {
    id: loadingTimer
    interval: 120
    repeat: true
    running: root.streaming && root.streamingText.length === 0
    onTriggered: {
      root.loadingTick = (root.loadingTick + 1) % 1000
      root.loadingElapsedSec += 0.12
    }
  }

  Timer {
    id: voicePulseTimer
    interval: 110
    repeat: true
    running: root.voiceState === "recording"
    onTriggered: root.voiceTick = (root.voiceTick + 1) % 1000
  }

  Process {
    id: loadCfgProc
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/config.py", "get", "--redact"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.config) {
          root.userConfig = res.config
          root.themeMode = String(res.config.theme || "system")
          var defMode = String(res.config.defaultMode || "lasso")
          if ((defMode === "lasso" || defMode === "box" || defMode === "text") && !root.selectionRect && !root.selectedText) {
            root.mode = defMode
          }
        }
      }
    }
  }

  Process {
    id: captureProc
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/capture.py"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.capturing = false
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (!res || !res.ok || !res.imagePath) {
          var err = res && res.error ? res.error : "capture failed"
          Quickshell.execDetached([
            root.omarchyPath + "/bin/omarchy-notification-send",
            "ScreenLens",
            Logic.neutralizeMarkup(strings.t("error.captureFailed").arg(err))
          ])
          root.dismiss()
          return
        }
        root.screenshotPath = res.imagePath
        root.imageWidth = Number(res.imageWidth) || 0
        root.imageHeight = Number(res.imageHeight) || 0
        root.windowClass = String(res.windowClass || "")
        root.windowTitle = String(res.windowTitle || "")
        root.opened = true

        root.ocrLoading = true
        ocrProc.command = ["/usr/bin/python3", root.pluginDir + "/scripts/ocr.py", root.screenshotPath]
        ocrProc.running = false
        ocrProc.running = true

        Qt.callLater(function() {
          promptField.forceActiveFocus()
        })
      }
    }
  }

  Process {
    id: ocrProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.ocrLoading = false
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && Array.isArray(res.words)) {
          root.rawOcrWords = res.words
          root.remapOcrWords()
        }
      }
    }
  }

  Process {
    id: extractProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.extractCancelled) return
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        var extracted = (res && res.ok && res.text) ? String(res.text).trim() : ""
        if (!extracted && root.selectionRect && root.ocrWords.length > 0) {
          var fallback = Logic.extractWordsInRect(root.ocrWords, root.selectionRect)
          if (fallback && fallback.text) extracted = String(fallback.text).trim()
        }
        if (extracted) {
          root.selectedText = extracted
          root.copyText(extracted)
        } else if (res && !res.ok && res.error) {
          root.showToast(String(res.error))
        } else {
          root.showToast(strings.t("status.noTextFound"))
        }
      }
    }
    onExited: {
      if (root.pendingExtractCommand) {
        var nextCmd = root.pendingExtractCommand
        root.pendingExtractCommand = null
        root.extractCancelled = false
        extractProc.command = nextCmd
        extractProc.running = true
      } else {
        root.extractCancelled = false
      }
    }
  }

  Process {
    id: askProc
    stdinEnabled: true
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/ask.py"]
    onStarted: askProc.write(root.pendingAskJson + "\n")
    stdout: SplitParser {
      onRead: function(line) { root.handleAskEvent(line) }
    }
    onExited: function(code) {
      if (root.streaming) {
        if (root.streamingText.length > 0) {
          var nextMessages = root.messages.slice()
          nextMessages.push({ role: "assistant", text: root.streamingText })
          root.messages = nextMessages
        } else if (code !== 0 && !root.errorMessage) {
          root.errorMessage = strings.t("error.askFailed").arg("exit " + code)
        }
        root.streaming = false
        root.streamingText = ""
      }
    }
  }

  Process {
    id: voiceStartProc
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/voice.py", "start"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok) {
          root.voiceBaseline = String(res.baseline || "")
          root.voiceState = "recording"
        } else {
          root.voiceState = "idle"
          root.errorMessage = strings.t("error.voiceFailed").arg(res && res.error ? res.error : "failed to start")
        }
      }
    }
  }

  Process {
    id: voiceStopProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.voiceState = "idle"
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok) {
          var transcript = String(res.text || "").trim()
          if (transcript) {
            var merged = Logic.mergeVoiceTranscript(root.voicePromptBefore, promptField.text, transcript)
            if (merged !== promptField.text) {
              root.voiceExpectedAfterInsert = merged
              root.voiceLastTranscript = transcript
              voiceDedupeTimer.restart()
              promptField.text = merged
            }
            promptField.cursorPosition = promptField.text.length
            promptField.forceActiveFocus()
          }
        } else {
          root.errorMessage = strings.t("error.voiceFailed").arg(res && res.error ? res.error : "failed to transcribe")
        }
      }
    }
  }

  // ---------------------------------------------------------------- overlay UI

  Ui.OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "screenlens"

    onWidthChanged: if (root.rawOcrWords.length > 0) root.remapOcrWords()
    onHeightChanged: if (root.rawOcrWords.length > 0) root.remapOcrWords()

    // Canvas gesture MouseArea (handles lasso drawing, OCR text drag, and
    // interactive crop move/resize handles cleanly without MouseArea conflicts).
    MouseArea {
      id: canvasMouse
      anchors.fill: parent
      hoverEnabled: true
      preventStealing: true
      cursorShape: root.mode === "text"
        ? Qt.IBeamCursor
        : (root.shiftKeyHeld && !root.draggingCanvas
            ? Qt.CrossCursor
            : root.cursorForHandle(root.dragHandle || root.hoverHandle))

      onPressed: function(mouse) {
        if (mouse.button !== Qt.LeftButton) return

        if (root.mode === "text") {
          root.draggingCanvas = true
          root.selectionRects = []
          root.activeRegionIndex = -1
          root.hoverRegionIndex = -1
          root.hoverHandle = ""
          root.textDragStartPoint = { x: mouse.x, y: mouse.y }
          root.textDragStartIdx = Logic.hitTestWord(root.ocrWords, mouse.x, mouse.y, 28)
          if (root.textDragStartIdx >= 0) {
            var single = Logic.selectWordsBetween(root.ocrWords, root.textDragStartIdx, root.textDragStartIdx, null)
            root.setSelectedWords(single.indices, single.text, single.bounds)
          } else {
            root.setSelectedWords([], "", null)
          }
          return
        }

        // In Circle/Box mode: check if grabbing a corner/edge/interior handle on a locked region.
        var shiftHeld = !!(mouse.modifiers & Qt.ShiftModifier) || root.shiftKeyHeld
        if (!shiftHeld && root.selectionRects.length > 0) {
          var hit = Logic.hitTestRegions(root.selectionRects, mouse.x, mouse.y, 12)
          if (hit.index >= 0 && hit.handle) {
            root.draggingCanvas = true
            root.activeRegionIndex = hit.index
            root.hoverRegionIndex = hit.index
            root.hoverHandle = hit.handle
            root.dragRegionIndex = hit.index
            root.dragHandle = hit.handle
            root.dragStartRect = root.selectionRects[hit.index]
            root.dragStartX = mouse.x
            root.dragStartY = mouse.y
            root.setSelectedWords([], "", null)
            return
          }
        }

        // Start a new region drag (Shift+drag pins an additional region).
        root.draggingCanvas = true
        root.dragRegionIndex = -1
        root.dragHandle = ""
        root.dragStartRect = null
        root.hoverRegionIndex = -1
        root.hoverHandle = ""
        root.setSelectedWords([], "", null)
        root.lassoPinMode = shiftHeld && root.selectionRects.length > 0
        if (!root.lassoPinMode) {
          root.selectionRects = []
          root.activeRegionIndex = -1
        }
        if (root.mode === "box") {
          root.lassoPoints = []
          root.lassoPathPoints = []
          root.boxStartPoint = { x: mouse.x, y: mouse.y }
          root.boxPreviewRect = null
        } else {
          root.boxStartPoint = null
          root.boxPreviewRect = null
          root.lassoPoints = [{ x: mouse.x, y: mouse.y }]
          root.lassoPathPoints = [Qt.point(mouse.x, mouse.y)]
        }
      }

      onPositionChanged: function(mouse) {
        if (!root.draggingCanvas) {
          if (root.isRegionMode && root.selectionRects.length > 0 && !root.shiftKeyHeld) {
            var hHit = Logic.hitTestRegions(root.selectionRects, mouse.x, mouse.y, 12)
            root.hoverRegionIndex = hHit.index
            root.hoverHandle = hHit.handle
          } else if (root.hoverRegionIndex !== -1 || root.hoverHandle !== "") {
            root.hoverRegionIndex = -1
            root.hoverHandle = ""
          }
          return
        }

        if (root.mode === "text") {
          var endIdx = Logic.hitTestWord(root.ocrWords, mouse.x, mouse.y, 32)
          var dragRect = null
          if (root.textDragStartPoint) {
            dragRect = {
              x: Math.min(root.textDragStartPoint.x, mouse.x),
              y: Math.min(root.textDragStartPoint.y, mouse.y),
              w: Math.abs(mouse.x - root.textDragStartPoint.x),
              h: Math.abs(mouse.y - root.textDragStartPoint.y)
            }
          }
          var sel = Logic.selectWordsBetween(root.ocrWords, root.textDragStartIdx, endIdx, dragRect)
          root.setSelectedWords(sel.indices, sel.text, sel.bounds)
          return
        }

        // Live move or resize of an existing locked crop region.
        if (root.dragRegionIndex >= 0 && root.dragHandle && root.dragStartRect) {
          var updated = Logic.applyCropDrag(
            root.dragStartRect,
            root.dragHandle,
            mouse.x - root.dragStartX,
            mouse.y - root.dragStartY,
            panel.width,
            panel.height,
            16
          )
          var nextRects = root.selectionRects.slice()
          nextRects[root.dragRegionIndex] = updated
          root.selectionRects = nextRects
          return
        }

        if (root.mode === "box" && root.boxStartPoint) {
          root.boxPreviewRect = Logic.computeBoxRect(
            root.boxStartPoint.x,
            root.boxStartPoint.y,
            mouse.x,
            mouse.y,
            panel.width,
            panel.height,
            2
          )
          return
        }

        var pts = root.lassoPoints.slice()
        var last = pts.length > 0 ? pts[pts.length - 1] : null
        if (!last || Math.hypot(mouse.x - last.x, mouse.y - last.y) >= 4) {
          pts.push({ x: mouse.x, y: mouse.y })
          root.lassoPoints = pts
          var pathPts = root.lassoPathPoints.slice()
          pathPts.push(Qt.point(mouse.x, mouse.y))
          root.lassoPathPoints = pathPts
        }
      }

      onReleased: function(mouse) {
        if (!root.draggingCanvas) return
        root.draggingCanvas = false

        if (root.dragRegionIndex >= 0) {
          root.dragRegionIndex = -1
          root.dragHandle = ""
          root.dragStartRect = null
          var postHit = Logic.hitTestRegions(root.selectionRects, mouse.x, mouse.y, 12)
          root.hoverRegionIndex = postHit.index
          root.hoverHandle = postHit.handle
          promptField.forceActiveFocus()
          return
        }

        if (root.isRegionMode) {
          var rect = null
          if (root.mode === "box" && root.boxStartPoint) {
            rect = Logic.computeBoxRect(
              root.boxStartPoint.x,
              root.boxStartPoint.y,
              mouse.x,
              mouse.y,
              panel.width,
              panel.height,
              8
            )
          } else {
            var pts = root.lassoPoints.slice()
            pts.push({ x: mouse.x, y: mouse.y })
            rect = Logic.computeSelectionRect(pts, panel.width, panel.height, 8)
          }
          var pin = root.lassoPinMode || ((!!(mouse.modifiers & Qt.ShiftModifier) || root.shiftKeyHeld) && root.selectionRects.length > 0)
          if (rect) {
            if (pin) {
              if (root.selectionRects.length >= root.maxPinnedRegions) {
                root.showToast(strings.t("status.maxRegions").arg(Commons.I18n.formatNumber(root.maxPinnedRegions)))
              } else {
                var pinned = root.selectionRects.slice()
                pinned.push(rect)
                root.selectionRects = pinned
                root.activeRegionIndex = pinned.length - 1
              }
            } else {
              root.selectionRects = [rect]
              root.activeRegionIndex = 0
            }
          }
          root.lassoPoints = []
          root.lassoPathPoints = []
          root.boxStartPoint = null
          root.boxPreviewRect = null
          root.lassoPinMode = false
        }
        promptField.forceActiveFocus()
      }

      onCanceled: {
        root.draggingCanvas = false
        root.dragRegionIndex = -1
        root.dragHandle = ""
        root.dragStartRect = null
        root.lassoPoints = []
        root.lassoPathPoints = []
        root.boxStartPoint = null
        root.boxPreviewRect = null
        root.lassoPinMode = false
      }

      onExited: {
        if (!root.draggingCanvas) {
          root.hoverRegionIndex = -1
          root.hoverHandle = ""
        }
      }
    }

    SLUi.CropOverlay {
      id: cropOverlay
      anchors.fill: parent
      regions: root.selectionRects
      imgCrops: root.currentImageCrops()
      previewRect: root.boxPreviewRect
      previewImgCrop: root.boxPreviewRect
        ? Logic.logicalToImageRect(root.boxPreviewRect, panel.width, panel.height, root.imageWidth, root.imageHeight)
        : null
      activeIndex: root.activeRegionIndex
      hoverIndex: root.dragRegionIndex >= 0 ? root.dragRegionIndex : root.hoverRegionIndex
      activeHandle: root.dragHandle || root.hoverHandle
      scrimColor: root.scrimColor
      accentColor: root.accentColor
      bgColor: root.bgColor
      fgColor: root.fgColor
      cornerRadius: root.cornerRadius
      uiFont: root.uiFont
      onRemoveRequested: function(idx) { root.removeRegion(idx) }
    }

    SLUi.EdgeGlow {
      id: edgeGlow
      anchors.fill: parent
      opened: root.opened
      glowColor: root.voiceState === "recording" ? root.urgentColor : root.accentColor
      activeBoost: root.draggingCanvas || root.streaming || root.voiceState === "recording"
    }

    // Native Qt Quick OCR word highlight boxes (visible only in Select Text mode).
    Item {
      anchors.fill: parent
      visible: root.mode === "text" && root.ocrWords.length > 0

      Repeater {
        model: root.mode === "text" ? root.ocrWords : []
        delegate: Rectangle {
          readonly property bool isSelected: root.selectedWordMap[index] === true
          x: modelData.x - 1
          y: modelData.y - 1
          width: modelData.w + 2
          height: modelData.h + 2
          radius: Math.min(3, Math.max(2, root.cornerRadius))
          color: isSelected
            ? Util.alpha(root.accentColor, 0.38)
            : Util.alpha(root.fgColor, 0.13)
          border.width: isSelected ? 1 : 0
          border.color: Util.alpha(root.accentColor, 0.90)
        }
      }
    }

    // Native GPU-rendered luminous 3-layer freehand lasso stroke while dragging.
    Shape {
      anchors.fill: parent
      visible: root.draggingCanvas && root.dragRegionIndex < 0 && root.mode === "lasso" && root.lassoPathPoints.length > 1
      preferredRendererType: Shape.CurveRenderer
      antialiasing: true

      // Outer ambient halo
      ShapePath {
        fillColor: "transparent"
        strokeColor: Util.alpha(root.accentColor, 0.16)
        strokeWidth: 20
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathPolyline { path: root.lassoPathPoints }
      }

      // Mid accent glow
      ShapePath {
        fillColor: "transparent"
        strokeColor: Util.alpha(root.accentColor, 0.44)
        strokeWidth: 9
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathPolyline { path: root.lassoPathPoints }
      }

      // Primary stroke
      ShapePath {
        fillColor: "transparent"
        strokeColor: root.accentColor
        strokeWidth: 3.5
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathPolyline { path: root.lassoPathPoints }
      }

      // Bright luminous filament core
      ShapePath {
        fillColor: "transparent"
        strokeColor: "#b8ffffff"
        strokeWidth: 1.5
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathPolyline { path: root.lassoPathPoints }
      }
    }

    // Floating quick actions right beside an active region or OCR text selection.
    Ui.BorderSurface {
      id: selectionBar
      readonly property var anchorBounds: root.selectedTextBounds || root.selectionRect
      visible: !!anchorBounds && !root.draggingCanvas
      color: root.bgColor
      borderSpec: root.cardBorderSpec
      radius: root.cornerRadius
      padding: Style.spacing.xs
      implicitWidth: selectionRow.implicitWidth + padding * 2 + Border.left(borderSpec) + Border.right(borderSpec)
      implicitHeight: selectionRow.implicitHeight + padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)
      x: anchorBounds
        ? Logic.clamp(anchorBounds.x + anchorBounds.w - width, Style.gapsOut, Math.max(Style.gapsOut, panel.width - width - Style.gapsOut))
        : 0
      y: anchorBounds
        ? (anchorBounds.y > height + Style.space(64)
            ? anchorBounds.y - height - Style.space(8)
            : Math.min(panel.height - dockContainer.height - height - Style.space(24), anchorBounds.y + anchorBounds.h + Style.space(8)))
        : 0

      SLUi.FloatingShadow { anchors.fill: parent; radius: selectionBar.radius }

      Row {
        id: selectionRow
        anchors.centerIn: parent
        spacing: Style.spacing.xs

        Ui.Button {
          foreground: root.fgColor
          visible: root.selectedText.length > 0
          text: strings.t("action.copyText")
          iconText: "󰆏"
          onClicked: root.copyText(root.selectedText)
        }

        Ui.Button {
          foreground: root.fgColor
          visible: !!root.selectionRect
          text: strings.t("chip.extractText")
          iconText: "󰗧"
          onClicked: root.extractAndCopyText()
        }

        Ui.Button {
          foreground: root.fgColor
          visible: !!root.selectionRect
          text: strings.t("action.copy")
          iconText: "󰋩"
          onClicked: root.copySelectedImage()
        }

        Ui.Button {
          foreground: root.fgColor
          text: strings.t("action.askSelection")
          iconText: "󰚩"
          selected: true
          onClicked: root.runQuickChip("explain")
        }

        Ui.Button {
          foreground: root.fgColor
          text: strings.t("action.handoff")
          iconText: "󰆍"
          onClicked: root.handoffToAgent()
        }

        Ui.Button {
          foreground: root.fgColor
          iconText: "󰅖"
          tooltipText: strings.t("context.clear")
          onClicked: root.clearSelection()
        }
      }
    }

    // --------------------------------------------------------- top mode bar

    Ui.BorderSurface {
      id: topBar
      anchors.top: parent.top
      anchors.topMargin: Math.max(Style.gapsOut, Style.space(16))
      anchors.horizontalCenter: parent.horizontalCenter
      color: root.bgColor
      borderSpec: root.cardBorderSpec
      radius: root.cornerRadius
      padding: Style.spacing.xs
      implicitWidth: topRow.implicitWidth + padding * 2 + Border.left(borderSpec) + Border.right(borderSpec) + Style.space(4)
      implicitHeight: topRow.implicitHeight + padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.97
      Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

      SLUi.FloatingShadow { anchors.fill: parent; radius: topBar.radius }
      MouseArea { anchors.fill: parent; onClicked: {} }

      Row {
        id: topRow
        anchors.centerIn: parent
        spacing: Style.spacing.xs

        // Compact recessed 3-way segmented mode switcher (Circle | Box | Text)
        Rectangle {
          id: modeTrack
          anchors.verticalCenter: parent.verticalCenter
          radius: Math.min(4, root.cornerRadius)
          color: root.restFill
          border.width: 1
          border.color: root.hairlineColor
          implicitWidth: modeSegRow.implicitWidth + Style.space(4)
          implicitHeight: modeSegRow.implicitHeight + Style.space(4)

          Row {
            id: modeSegRow
            anchors.centerIn: parent
            spacing: Style.space(2)

            Repeater {
              model: [
                { id: "lasso", icon: "󰴲", label: strings.t("mode.lasso") },
                { id: "box",   icon: "󰒉", label: strings.t("mode.box") },
                { id: "text",  icon: "󰗧", label: strings.t("mode.text") }
              ]
              delegate: Rectangle {
                id: modeSeg
                required property var modelData
                readonly property bool active: root.mode === modelData.id
                radius: Math.min(3, root.cornerRadius)
                color: active ? Util.alpha(root.accentColor, 0.22) : (segHover.hovered ? root.hoverFill : "transparent")
                border.width: active ? 1 : 0
                border.color: Util.alpha(root.accentColor, 0.65)
                implicitWidth: segRow.implicitWidth + Style.space(12)
                implicitHeight: Style.space(24)

                Row {
                  id: segRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)
                  PlainText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.icon
                    color: modeSeg.active ? root.accentColor : root.mutedInk
                    font.family: root.uiFont
                    font.pixelSize: Style.font.body
                  }
                  PlainText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.label
                    color: modeSeg.active ? root.fgColor : Util.alpha(root.fgColor, 0.72)
                    font.family: root.uiFont
                    font.pixelSize: Style.font.bodySmall
                    font.bold: modeSeg.active
                  }
                }

                HoverHandler { id: segHover; cursorShape: Qt.PointingHandCursor }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setMode(modelData.id)
                }
              }
            }
          }
        }

        Ui.Button {
          foreground: root.fgColor
          text: strings.t("mode.fullScreen")
          iconText: "󰊓"
          fontSize: Style.font.bodySmall
          visible: !!root.selectionRect || root.selectedText.length > 0
          onClicked: root.clearSelection()
        }

        Rectangle {
          width: 1
          height: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          color: root.hairlineColor
        }

        Row {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)
          leftPadding: Style.space(4)
          rightPadding: Style.space(4)

          // Live OCR status dot
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: Style.space(6)
            radius: width / 2
            color: root.ocrLoading
              ? root.accentColor
              : (root.ocrWords.length > 0 ? Util.alpha(root.accentColor, 0.78) : root.mutedInk)
          }

          PlainText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.ocrLoading
              ? strings.t("hint.ocrLoading")
              : (root.mode === "text"
                  ? (root.ocrWords.length > 0
                      ? strings.tn("hint.ocrReady", root.ocrWords.length).arg(Commons.I18n.formatNumber(root.ocrWords.length))
                      : strings.t("hint.ocrEmpty"))
                  : (root.selectionRects.length > 0
                      ? strings.t("hint.lassoLocked")
                      : (root.mode === "box" ? strings.t("hint.box") : strings.t("hint.lasso"))))
            color: Util.alpha(root.fgColor, 0.68)
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle {
          width: 1
          height: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          color: root.hairlineColor
        }

        Ui.Button {
          foreground: root.fgColor
          iconText: "󰒓"
          tooltipText: strings.t("settings.openTooltip")
          onClicked: root.openSettings()
        }

        Ui.Button {
          foreground: root.fgColor
          iconText: "󰅖"
          tooltipText: strings.t("action.close")
          onClicked: root.dismiss()
        }
      }
    }

    // -------------------------------------------------------- bottom dock

    Column {
      id: dockContainer
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Math.max(Style.gapsOut, Style.space(22))
      anchors.horizontalCenter: parent.horizontalCenter
      width: Math.min(Style.space(760), panel.width - Style.gapsOut * 4)
      spacing: Style.spacing.sm

      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.97
      Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

      // Reel-inspired toast pill with leading accent bar
      Ui.BorderSurface {
        id: toastPill
        visible: root.toastMessage.length > 0
        anchors.horizontalCenter: parent.horizontalCenter
        color: root.bgColor
        borderSpec: Border.flat(Util.alpha(root.accentColor, 0.45), 1)
        radius: root.cornerRadius
        padding: Style.spacing.xs
        implicitWidth: toastRow.implicitWidth + Style.spacing.md * 2
        implicitHeight: toastRow.implicitHeight + Style.spacing.xs * 2 + Style.space(2)

        SLUi.FloatingShadow { anchors.fill: parent; radius: toastPill.radius }

        Row {
          id: toastRow
          anchors.centerIn: parent
          spacing: Style.space(7)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: Style.space(6)
            radius: width / 2
            color: root.accentColor
          }

          PlainText {
            id: toastLabel
            anchors.verticalCenter: parent.verticalCenter
            text: root.toastMessage
            color: root.fgColor
            font.family: root.uiFont
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      // Streaming Answer & Conversation Card
      Ui.BorderSurface {
        id: answerCard
        visible: root.messages.length > 0 || root.streaming || root.errorMessage.length > 0
        width: parent.width
        color: root.bgColor
        borderSpec: root.cardBorderSpec
        radius: root.cornerRadius
        padding: Style.spacing.panelPadding
        readonly property real maxBodyHeight: Math.min(panel.height * 0.44, Style.space(440))
        implicitHeight: answerHeader.implicitHeight
          + 1
          + Math.min(maxBodyHeight, Math.max(Style.space(44), answerColumn.implicitHeight + Style.spacing.sm))
          + Style.spacing.panelPadding * 2
          + Style.spacing.sm * 2
          + Border.top(borderSpec) + Border.bottom(borderSpec)

        SLUi.FloatingShadow { anchors.fill: parent; radius: answerCard.radius }
        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
          anchors.fill: parent
          anchors.topMargin: answerCard.contentTopInset
          anchors.rightMargin: answerCard.contentRightInset
          anchors.bottomMargin: answerCard.contentBottomInset
          anchors.leftMargin: answerCard.contentLeftInset
          spacing: Style.spacing.sm

          // Header row with provider badge + Copy / Continue in Agent / Clear
          Item {
            id: answerHeader
            width: parent.width
            implicitHeight: Math.max(providerRow.implicitHeight, answerActionRow.implicitHeight)

            Row {
              id: providerRow
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(7)
                height: Style.space(7)
                radius: width / 2
                color: root.accentColor
              }

              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: (root.providerLabel || strings.t("app.title")).toUpperCase()
                color: Util.alpha(root.fgColor, 0.72)
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.8
              }

              Rectangle {
                visible: root.answerUsedWebSearch
                anchors.verticalCenter: parent.verticalCenter
                radius: Math.min(3, root.cornerRadius)
                color: Util.alpha(root.accentColor, 0.16)
                border.width: 1
                border.color: Util.alpha(root.accentColor, 0.42)
                implicitWidth: webBadgeRow.implicitWidth + Style.space(10)
                implicitHeight: webBadgeRow.implicitHeight + Style.space(4)

                Row {
                  id: webBadgeRow
                  anchors.centerIn: parent
                  spacing: Style.space(4)

                  PlainText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰖟"
                    color: root.accentColor
                    font.family: root.uiFont
                    font.pixelSize: Style.font.caption
                  }

                  PlainText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: strings.t("status.webGrounded")
                    color: root.accentColor
                    font.family: root.uiFont
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 0.6
                  }
                }
              }

              PlainText {
                visible: root.streaming
                anchors.verticalCenter: parent.verticalCenter
                text: "· " + strings.t("status.thinking")
                color: root.accentColor
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Row {
              id: answerActionRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xs

              Ui.Button {
                foreground: root.fgColor
                visible: root.latestAssistantText().length > 0
                text: strings.t("action.copy")
                iconText: "󰆏"
                fontSize: Style.font.bodySmall
                onClicked: root.copyText(root.latestAssistantText())
              }

              Ui.Button {
                foreground: root.fgColor
                text: strings.t("action.handoff")
                iconText: "󰆍"
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: root.handoffToAgent()
              }

              Ui.Button {
                foreground: root.fgColor
                text: strings.t("action.newChat")
                iconText: "󰃢"
                fontSize: Style.font.bodySmall
                onClicked: {
                  root.cancelStreaming()
                  root.messages = []
                  root.errorMessage = ""
                  root.answerUsedWebSearch = false
                }
              }
            }
          }

          // Subtle header hairline divider
          Rectangle {
            width: parent.width
            height: 1
            color: root.hairlineColor
          }

          // Scrollable conversation history
          Flickable {
            id: answerScroll
            width: parent.width
            height: Math.min(answerCard.maxBodyHeight, Math.max(Style.space(44), answerColumn.implicitHeight + Style.spacing.xs))
            contentWidth: width
            contentHeight: answerColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            Column {
              id: answerColumn
              width: answerScroll.width - Style.space(6)
              spacing: Style.spacing.sm

              Repeater {
                model: root.messages
                delegate: Rectangle {
                  required property var modelData
                  readonly property bool isUser: modelData.role === "user"
                  width: answerColumn.width
                  radius: Math.min(4, root.cornerRadius)
                  color: isUser
                    ? Util.alpha(root.accentColor, 0.11)
                    : Util.alpha(root.fgColor, 0.035)
                  border.width: 1
                  border.color: isUser
                    ? Util.alpha(root.accentColor, 0.25)
                    : Util.alpha(root.fgColor, 0.07)
                  clip: true
                  implicitHeight: (isUser ? userMsgText.implicitHeight : assistantBlocks.implicitHeight) + Style.spacing.sm * 2 + Style.space(4)

                  // Subtle 3 px left accent edge on user prompts
                  Rectangle {
                    visible: parent.isUser
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Style.space(3)
                    color: root.accentColor
                  }

                  PlainText {
                    id: userMsgText
                    visible: parent.isUser
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.leftMargin: Style.spacing.md + Style.space(3)
                    anchors.rightMargin: Style.spacing.md
                    anchors.topMargin: Style.spacing.sm + Style.space(2)
                    text: modelData.text
                    color: root.fgColor
                    font.family: root.uiFont
                    font.pixelSize: Style.font.body
                    font.bold: true
                    wrapMode: Text.Wrap
                  }

                  SLUi.AnswerBlocks {
                    id: assistantBlocks
                    visible: !parent.isUser
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.leftMargin: Style.spacing.md
                    anchors.rightMargin: Style.spacing.md
                    anchors.topMargin: Style.spacing.sm + Style.space(2)
                    blocks: parent.isUser ? [] : Logic.parseAnswerBlocks(modelData.text)
                    fgColor: root.fgColor
                    accentColor: root.accentColor
                    hairlineColor: root.hairlineColor
                    hoverFill: root.hoverFill
                    mutedInk: root.mutedInk
                    cornerRadius: root.cornerRadius
                    uiFont: root.uiFont
                    copyLabel: strings.t("action.copy")
                    onCopyRequested: function(txt) { root.copyText(txt) }
                  }
                }
              }

              // Sleek translucent shimmer loading card (animates even with reduced motion)
              Rectangle {
                id: loadingBanner
                visible: root.streaming && root.streamingText.length === 0
                width: answerColumn.width
                radius: Math.min(4, root.cornerRadius)
                color: Util.alpha(root.accentColor, 0.09)
                border.width: 1
                border.color: Util.alpha(root.accentColor, 0.38)
                clip: true
                implicitHeight: loadingRow.implicitHeight + Style.spacing.md * 2 + Style.space(2)

                // 3 px leading accent hairline
                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Style.space(3)
                  color: root.accentColor
                }

                Item {
                  id: loadingRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.leftMargin: Style.spacing.md + Style.space(4)
                  anchors.rightMargin: Style.spacing.md
                  anchors.topMargin: Style.spacing.md
                  implicitHeight: Math.max(spinnerGlyph.implicitHeight, loadingTitle.implicitHeight, elapsedLabel.implicitHeight)

                  PlainText {
                    id: spinnerGlyph
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.spinnerFrames[root.loadingTick % root.spinnerFrames.length]
                    color: root.accentColor
                    font.family: root.uiFont
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }

                  PlainText {
                    id: loadingTitle
                    anchors.left: spinnerGlyph.right
                    anchors.leftMargin: Style.spacing.sm
                    anchors.right: elapsedLabel.left
                    anchors.rightMargin: Style.spacing.sm
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.webSearchEnabled ? strings.t("status.searchingWeb") : strings.t("status.analyzing")
                    color: root.fgColor
                    font.family: root.uiFont
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  PlainText {
                    id: elapsedLabel
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: Commons.I18n.formatNumber(root.loadingElapsedSec, 1) + "s"
                    color: root.accentColor
                    font.family: root.uiFont
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                // Sweeping 2 px luminous activity hairline along the bottom edge
                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: 2
                  color: Util.alpha(root.accentColor, 0.16)

                  Rectangle {
                    readonly property real trackWidth: parent.width
                    readonly property real barWidth: Math.max(Style.space(56), trackWidth * 0.26)
                    readonly property real phase: ((root.loadingTick * 0.055) % 1.0)
                    x: -barWidth + phase * (trackWidth + barWidth)
                    width: barWidth
                    height: parent.height
                    gradient: Gradient {
                      orientation: Gradient.Horizontal
                      GradientStop { position: 0.0; color: "transparent" }
                      GradientStop { position: 0.5; color: root.accentColor }
                      GradientStop { position: 1.0; color: "transparent" }
                    }
                  }
                }
              }

              // Active streaming reply (structured live with PlainText-safe blocks)
              Rectangle {
                visible: root.streaming && root.streamingText.length > 0
                width: answerColumn.width
                radius: Math.min(4, root.cornerRadius)
                color: Util.alpha(root.fgColor, 0.035)
                border.width: 1
                border.color: Util.alpha(root.accentColor, 0.28)
                implicitHeight: streamBlocks.implicitHeight + Style.spacing.sm * 2 + Style.space(4)

                SLUi.AnswerBlocks {
                  id: streamBlocks
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.leftMargin: Style.spacing.md
                  anchors.rightMargin: Style.spacing.md
                  anchors.topMargin: Style.spacing.sm + Style.space(2)
                  blocks: root.streamingText.length > 0 ? Logic.parseAnswerBlocks(root.streamingText) : []
                  fgColor: root.fgColor
                  accentColor: root.accentColor
                  hairlineColor: root.hairlineColor
                  hoverFill: root.hoverFill
                  mutedInk: root.mutedInk
                  cornerRadius: root.cornerRadius
                  uiFont: root.uiFont
                  copyLabel: strings.t("action.copy")
                  onCopyRequested: function(txt) { root.copyText(txt) }
                }
              }

              // Inline error box with 3 px urgent leading bar
              Rectangle {
                visible: root.errorMessage.length > 0
                width: answerColumn.width
                radius: Math.min(4, root.cornerRadius)
                color: Util.alpha(root.urgentColor, 0.14)
                border.width: 1
                border.color: Util.alpha(root.urgentColor, 0.52)
                clip: true
                implicitHeight: errText.implicitHeight + Style.spacing.sm * 2 + Style.space(2)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  width: Style.space(3)
                  color: root.urgentColor
                }

                PlainText {
                  id: errText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.leftMargin: Style.spacing.md + Style.space(3)
                  anchors.rightMargin: Style.spacing.md
                  anchors.topMargin: Style.spacing.sm + Style.space(1)
                  text: root.errorMessage
                  color: root.fgColor
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }
      }

      // Quick-action chips row with subtle keycap badges
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.xs

        Repeater {
          model: [
            { kind: "explain",   icon: "󰋗", label: strings.t("chip.explain"),     key: "Alt+1" },
            { kind: "summarize", icon: "󰦨", label: strings.t("chip.summarize"),   key: "Alt+2" },
            { kind: "translate", icon: "󰗊", label: strings.t("chip.translate"),   key: "Alt+3" },
            { kind: "extract",   icon: "󰗧", label: strings.t("chip.extractText"), key: "Alt+4" }
          ]
          delegate: Rectangle {
            id: chipRect
            required property var modelData
            radius: Math.min(4, root.cornerRadius)
            color: chipHover.hovered ? root.bgColor : Util.alpha(root.bgColor, 0.92)
            border.width: 1
            border.color: chipHover.hovered ? Util.alpha(root.accentColor, 0.72) : root.hairlineColor
            implicitWidth: chipRow.implicitWidth + Style.space(18)
            implicitHeight: Style.space(28)

            SLUi.FloatingShadow { anchors.fill: parent; radius: chipRect.radius }

            Row {
              id: chipRow
              anchors.centerIn: parent
              spacing: Style.space(6)

              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.icon
                color: chipHover.hovered ? root.accentColor : Util.alpha(root.fgColor, 0.72)
                font.family: root.uiFont
                font.pixelSize: Style.font.body
              }

              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                color: root.fgColor
                font.family: root.uiFont
                font.pixelSize: Style.font.bodySmall
              }

              SLUi.KeyCap {
                anchors.verticalCenter: parent.verticalCenter
                label: modelData.key
                fgColor: root.fgColor
                cornerRadius: root.cornerRadius
                uiFont: root.uiFont
              }
            }

            HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.runQuickChip(modelData.kind)
            }
          }
        }
      }

      // Main floating prompt bar
      Ui.BorderSurface {
        id: promptBar
        width: parent.width
        color: root.bgColor
        borderSpec: root.cardBorderSpec
        radius: root.cornerRadius
        padding: Style.spacing.md
        implicitHeight: promptColumn.implicitHeight + padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

        SLUi.FloatingShadow { anchors.fill: parent; radius: promptBar.radius }
        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
          id: promptColumn
          anchors.fill: parent
          anchors.topMargin: promptBar.contentTopInset
          anchors.rightMargin: promptBar.contentRightInset
          anchors.bottomMargin: promptBar.contentBottomInset
          anchors.leftMargin: promptBar.contentLeftInset
          spacing: Style.spacing.xs

          // Context badge, Web Search grounding toggle & live voice status strip
          Item {
            width: parent.width
            implicitHeight: Math.max(ctxBadge.implicitHeight, webSearchToggle.implicitHeight, voiceStrip.implicitHeight)

            Rectangle {
              id: ctxBadge
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              radius: Math.min(4, root.cornerRadius)
              color: Util.alpha(root.accentColor, 0.14)
              border.width: 1
              border.color: Util.alpha(root.accentColor, 0.34)
              implicitHeight: ctxRow.implicitHeight + Style.space(5)
              implicitWidth: ctxRow.implicitWidth + Style.space(14)

              Row {
                id: ctxRow
                anchors.centerIn: parent
                spacing: Style.space(6)

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(5)
                  height: Style.space(5)
                  radius: width / 2
                  color: root.accentColor
                }

                PlainText {
                  id: ctxLabel
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.contextBadgeText()
                  color: root.accentColor
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }

            // Optional Live Web Search grounding toggle pill (Ctrl+G)
            Rectangle {
              id: webSearchToggle
              anchors.left: ctxBadge.right
              anchors.leftMargin: Style.spacing.xs
              anchors.verticalCenter: parent.verticalCenter
              radius: Math.min(4, root.cornerRadius)
              color: root.webSearchEnabled
                ? Util.alpha(root.accentColor, 0.22)
                : (webToggleHover.hovered ? root.hoverFill : root.restFill)
              border.width: 1
              border.color: root.webSearchEnabled
                ? Util.alpha(root.accentColor, 0.72)
                : (webToggleHover.hovered ? Util.alpha(root.fgColor, 0.28) : root.hairlineColor)
              implicitHeight: ctxBadge.implicitHeight
              implicitWidth: webToggleRow.implicitWidth + Style.space(14)

              Row {
                id: webToggleRow
                anchors.centerIn: parent
                spacing: Style.space(5)

                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰖟"
                  color: root.webSearchEnabled ? root.accentColor : root.mutedInk
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                }

                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("prompt.webSearch")
                  color: root.webSearchEnabled ? root.fgColor : Util.alpha(root.fgColor, 0.72)
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                  font.bold: root.webSearchEnabled
                }
              }

              HoverHandler { id: webToggleHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.webSearchEnabled = !root.webSearchEnabled
                  promptField.forceActiveFocus()
                }
              }

              Ui.PanelToolTip {
                visible: webToggleHover.hovered
                text: strings.t("prompt.webSearchTooltip")
              }
            }

            // Live voice recording waveform & status
            Row {
              id: voiceStrip
              visible: root.voiceState !== "idle"
              anchors.left: webSearchToggle.right
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Row {
                visible: root.voiceState === "recording"
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                height: Style.space(12)

                Repeater {
                  model: 4
                  delegate: Rectangle {
                    required property int index
                    readonly property real wave: 0.35 + 0.65 * Math.abs(Math.sin((root.voiceTick * 0.55) + index * 1.1))
                    anchors.verticalCenter: parent.verticalCenter
                    width: 2
                    height: Math.max(3, Math.round(Style.space(12) * wave))
                    radius: 1
                    color: root.urgentColor
                  }
                }
              }

              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.voiceState === "recording"
                  ? strings.t("voice.listening")
                  : strings.t("voice.transcribing")
                color: root.voiceState === "recording" ? root.urgentColor : root.accentColor
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            // Quiet keyboard hints aligned right
            Row {
              visible: root.voiceState === "idle"
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)
              opacity: 0.72

              Row {
                spacing: Style.space(4)
                SLUi.KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "Tab"; fgColor: root.fgColor; cornerRadius: root.cornerRadius; uiFont: root.uiFont }
                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Mode"
                  color: root.mutedInk
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                spacing: Style.space(4)
                SLUi.KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "Ctrl+G"; fgColor: root.fgColor; cornerRadius: root.cornerRadius; uiFont: root.uiFont }
                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("prompt.webSearch")
                  color: root.webSearchEnabled ? root.accentColor : root.mutedInk
                  font.family: root.uiFont
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                spacing: Style.space(4)
                SLUi.KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "Ctrl+M"; fgColor: root.fgColor; cornerRadius: root.cornerRadius; uiFont: root.uiFont }
                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Voice"
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
          }

          // Input + Superwhisper Voice + Send/Stop + Agent Handoff
          Row {
            id: inputRow
            width: parent.width
            spacing: Style.spacing.xs

            Ui.TextField {
              id: promptField
              width: inputRow.width - voiceBtn.implicitWidth - sendBtn.implicitWidth - handoffBtn.implicitWidth - inputRow.spacing * 3
              placeholderText: root.messages.length > 0
                ? strings.t("prompt.followUpPlaceholder")
                : strings.t("prompt.placeholder")
              foreground: root.fgColor
              accent: root.accentColor
              font.family: root.uiFont
              onAccepted: root.submitPrompt()
              onTextChanged: {
                if (voiceDedupeTimer.running && root.voiceLastTranscript && root.voiceExpectedAfterInsert) {
                  var cleaned = Logic.dedupeLateVoicePaste(promptField.text, root.voiceExpectedAfterInsert, root.voiceLastTranscript)
                  if (cleaned !== promptField.text) {
                    voiceDedupeTimer.stop()
                    root.voiceExpectedAfterInsert = ""
                    root.voiceLastTranscript = ""
                    promptField.text = cleaned
                    promptField.cursorPosition = promptField.text.length
                  }
                }
              }

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Shift) {
                  root.shiftKeyHeld = true
                  return
                }
                if (event.key === Qt.Key_Escape) {
                  root.handleEscape()
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  root.cycleMode((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Backtab) {
                  root.cycleMode(-1)
                  event.accepted = true
                } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_G) {
                  root.webSearchEnabled = !root.webSearchEnabled
                  event.accepted = true
                } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_M) {
                  root.toggleVoice()
                  event.accepted = true
                } else if ((event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier)
                    && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                  root.handoffToAgent()
                  event.accepted = true
                } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_C && !promptField.selectedText) {
                  root.copyContextOrAnswer()
                  event.accepted = true
                } else if (event.modifiers & Qt.AltModifier) {
                  if (event.key === Qt.Key_1) { root.runQuickChip("explain"); event.accepted = true }
                  else if (event.key === Qt.Key_2) { root.runQuickChip("summarize"); event.accepted = true }
                  else if (event.key === Qt.Key_3) { root.runQuickChip("translate"); event.accepted = true }
                  else if (event.key === Qt.Key_4) { root.runQuickChip("extract"); event.accepted = true }
                }
              }

              Keys.onReleased: function(event) {
                if (event.key === Qt.Key_Shift) {
                  root.shiftKeyHeld = false
                }
              }
            }

            Ui.Button {
              id: voiceBtn
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.voiceState === "recording" ? "󰓛" : "󰍬"
              iconSpinning: root.voiceState === "transcribing"
              foreground: root.voiceState === "recording" ? root.urgentColor : root.fgColor
              selected: root.voiceState === "recording"
              bordered: true
              tooltipText: strings.t("voice.start")
              onClicked: root.toggleVoice()
            }

            Ui.Button {
              foreground: root.fgColor
              id: sendBtn
              anchors.verticalCenter: parent.verticalCenter
              text: root.streaming ? strings.t("prompt.stop") : strings.t("prompt.send")
              iconText: root.streaming ? "󰑓" : "󰁕"
              iconSpinning: root.streaming
              selected: !root.streaming
              bordered: true
              onClicked: {
                if (root.streaming) root.cancelStreaming()
                else root.submitPrompt()
              }
            }

            Ui.Button {
              foreground: root.fgColor
              id: handoffBtn
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰆍"
              bordered: true
              tooltipText: strings.t("action.handoff")
              onClicked: root.handoffToAgent()
            }
          }
        }
      }
    }
  }
}
