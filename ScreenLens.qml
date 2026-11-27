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

  // Interaction mode: "lasso" (freehand circle / box) or "text" (OCR word selection)
  property string mode: "lasso"
  property var lassoPoints: []
  property var lassoPathPoints: [] // Array of Qt.point() for PathPolyline
  property bool draggingCanvas: false
  property var selectionRect: null // {x, y, w, h} in logical overlay coordinates

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

  // Pending stdin payloads for Process helpers
  property string pendingAskJson: ""
  property string pendingCopyJson: ""
  property string pendingHandoffJson: ""

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
    root.draggingCanvas = false
    root.selectionRect = null
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
    if (extractProc.running) extractProc.running = false
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
    root.selectionRect = null
    root.setSelectedWords([], "", null)
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
    root.loadingTick = 0
    root.loadingElapsedSec = 0
    root.streaming = true

    var payload = {
      prompt: text,
      task: root.inferTask(explicitTask),
      imagePath: root.screenshotPath,
      crop: root.currentImageCrop(),
      selectedText: root.selectedText,
      windowInfo: { class: root.windowClass, title: root.windowTitle },
      history: history
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
    if (!root.screenshotPath) return
    root.showToast(strings.t("status.extractingText"))
    var args = ["/usr/bin/python3", root.pluginDir + "/scripts/ocr.py", root.screenshotPath, "--text-only", "--copy"]
    var crop = root.currentImageCrop()
    if (crop) {
      args.push("--crop")
      args.push(crop.x + "," + crop.y + "," + crop.w + "," + crop.h)
    }
    extractProc.running = false
    extractProc.command = args
    extractProc.running = true
  }

  function copyText(text) {
    var s = String(text || "")
    if (!s) return
    root.pendingCopyJson = JSON.stringify({ text: s })
    copyTextProc.running = false
    copyTextProc.running = true
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
          if ((defMode === "lasso" || defMode === "text") && !root.selectionRect && !root.selectedText) {
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
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.text) {
          root.selectedText = res.text
          root.showToast(strings.t("status.copiedToClipboard"))
        } else {
          root.showToast(strings.t("status.noTextFound"))
        }
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
    id: copyTextProc
    stdinEnabled: true
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/actions.py", "copy-text", "-"]
    onStarted: copyTextProc.write(root.pendingCopyJson + "\n")
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

    SLUi.CropOverlay {
      id: cropOverlay
      anchors.fill: parent
      selectionRect: root.selectionRect
      imgCrop: root.currentImageCrop()
      scrimColor: root.scrimColor
      accentColor: root.accentColor
      bgColor: root.bgColor
      cornerRadius: root.cornerRadius
      uiFont: root.uiFont
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
      visible: root.draggingCanvas && root.mode === "lasso" && root.lassoPathPoints.length > 1
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

    // Canvas gesture MouseArea (sits behind the floating UI controls).
    MouseArea {
      id: canvasMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: root.mode === "text" ? Qt.IBeamCursor : Qt.CrossCursor

      onPressed: function(mouse) {
        if (mouse.button !== Qt.LeftButton) return
        root.draggingCanvas = true

        if (root.mode === "text") {
          root.selectionRect = null
          root.textDragStartPoint = { x: mouse.x, y: mouse.y }
          root.textDragStartIdx = Logic.hitTestWord(root.ocrWords, mouse.x, mouse.y, 28)
          if (root.textDragStartIdx >= 0) {
            var single = Logic.selectWordsBetween(root.ocrWords, root.textDragStartIdx, root.textDragStartIdx, null)
            root.setSelectedWords(single.indices, single.text, single.bounds)
          } else {
            root.setSelectedWords([], "", null)
          }
        } else {
          root.setSelectedWords([], "", null)
          root.selectionRect = null
          root.lassoPoints = [{ x: mouse.x, y: mouse.y }]
          root.lassoPathPoints = [Qt.point(mouse.x, mouse.y)]
        }
      }

      onPositionChanged: function(mouse) {
        if (!root.draggingCanvas) return
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
        } else {
          var pts = root.lassoPoints
          var last = pts.length > 0 ? pts[pts.length - 1] : null
          if (!last || Math.hypot(mouse.x - last.x, mouse.y - last.y) >= 4) {
            pts.push({ x: mouse.x, y: mouse.y })
            root.lassoPoints = pts
            var pathPts = root.lassoPathPoints.slice()
            pathPts.push(Qt.point(mouse.x, mouse.y))
            root.lassoPathPoints = pathPts
          }
        }
      }

      onReleased: function(mouse) {
        if (!root.draggingCanvas) return
        root.draggingCanvas = false
        if (root.mode === "lasso") {
          var pts = root.lassoPoints.slice()
          pts.push({ x: mouse.x, y: mouse.y })
          root.selectionRect = Logic.computeSelectionRect(pts, panel.width, panel.height, 8)
          root.lassoPoints = []
          root.lassoPathPoints = []
        }
        promptField.forceActiveFocus()
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

        // Compact recessed segmented mode switcher (Circle | Select Text)
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

            Rectangle {
              id: lassoSeg
              readonly property bool active: root.mode === "lasso"
              radius: Math.min(3, root.cornerRadius)
              color: active ? Util.alpha(root.accentColor, 0.22) : (lassoHover.hovered ? root.hoverFill : "transparent")
              border.width: active ? 1 : 0
              border.color: Util.alpha(root.accentColor, 0.65)
              implicitWidth: lassoSegRow.implicitWidth + Style.space(14)
              implicitHeight: Style.space(24)

              Row {
                id: lassoSegRow
                anchors.centerIn: parent
                spacing: Style.space(5)
                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰒅"
                  color: lassoSeg.active ? root.accentColor : root.mutedInk
                  font.family: root.uiFont
                  font.pixelSize: Style.font.body
                }
                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("mode.lasso")
                  color: lassoSeg.active ? root.fgColor : Util.alpha(root.fgColor, 0.72)
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  font.bold: lassoSeg.active
                }
              }

              HoverHandler { id: lassoHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.mode = "lasso"
                  promptField.forceActiveFocus()
                }
              }
            }

            Rectangle {
              id: textSeg
              readonly property bool active: root.mode === "text"
              radius: Math.min(3, root.cornerRadius)
              color: active ? Util.alpha(root.accentColor, 0.22) : (textModeHover.hovered ? root.hoverFill : "transparent")
              border.width: active ? 1 : 0
              border.color: Util.alpha(root.accentColor, 0.65)
              implicitWidth: textSegRow.implicitWidth + Style.space(14)
              implicitHeight: Style.space(24)

              Row {
                id: textSegRow
                anchors.centerIn: parent
                spacing: Style.space(5)
                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰗧"
                  color: textSeg.active ? root.accentColor : root.mutedInk
                  font.family: root.uiFont
                  font.pixelSize: Style.font.body
                }
                PlainText {
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("mode.text")
                  color: textSeg.active ? root.fgColor : Util.alpha(root.fgColor, 0.72)
                  font.family: root.uiFont
                  font.pixelSize: Style.font.bodySmall
                  font.bold: textSeg.active
                }
              }

              HoverHandler { id: textModeHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.mode = "text"
                  promptField.forceActiveFocus()
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
                  : strings.t("hint.lasso"))
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
                    text: strings.t("status.analyzing")
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

          // Context badge & live voice status strip
          Item {
            width: parent.width
            implicitHeight: Math.max(ctxBadge.implicitHeight, voiceStrip.implicitHeight)

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

            // Live voice recording waveform & status
            Row {
              id: voiceStrip
              visible: root.voiceState !== "idle"
              anchors.left: ctxBadge.right
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
                if (event.key === Qt.Key_Escape) {
                  root.handleEscape()
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  root.mode = (root.mode === "lasso") ? "text" : "lasso"
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
