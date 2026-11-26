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

  // Superwhisper voice state: "idle" | "recording" | "transcribing"
  property string voiceState: "idle"
  property string voiceBaseline: ""

  // Pending stdin payloads for Process helpers
  property string pendingAskJson: ""
  property string pendingCopyJson: ""
  property string pendingHandoffJson: ""

  // Surface tokens aligned with Omarchy's menu & popup surfaces
  readonly property color bgColor: Commons.Color.menu.background
  readonly property color fgColor: Commons.Color.menu.text
  readonly property color accentColor: Commons.Color.accent
  readonly property color urgentColor: Commons.Color.urgent
  readonly property color borderColor: Commons.Color.menu.border
  readonly property var cardBorderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
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
      root.shell.hide((root.manifest && root.manifest.id) || "carlos.screenlens")
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

  function submitPrompt(overridePrompt) {
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
    root.streaming = true

    var payload = {
      prompt: text,
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
      root.submitPrompt("Explain what is shown here clearly and concisely.")
    } else if (kind === "summarize") {
      root.submitPrompt("Summarize the key points shown here in concise bullets.")
    } else if (kind === "translate") {
      root.submitPrompt("Translate any visible text here into English. If it is already in English, briefly clarify any jargon or idioms.")
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
    var handoffPrompt = Logic.buildAgentHandoffPrompt({
      windowClass: root.windowClass,
      windowTitle: root.windowTitle,
      imagePath: root.screenshotPath,
      crop: crop,
      selectedText: root.selectedText,
      messages: allMsgs,
      draftPrompt: promptField.text
    })
    root.pendingHandoffJson = JSON.stringify({
      prompt: handoffPrompt,
      imagePath: root.screenshotPath,
      crop: crop,
      draftPrompt: promptField.text
    })
    handoffProc.running = false
    handoffProc.running = true
  }

  function toggleVoice() {
    if (root.voiceState === "transcribing") return
    if (root.voiceState === "idle") {
      root.errorMessage = ""
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
      return strings.t("context.selectedText").arg(Commons.I18n.formatNumber(root.selectedText.length))
    }
    if (root.selectionRect) {
      var crop = root.currentImageCrop()
      var w = crop ? crop.w : Math.round(root.selectionRect.w)
      var h = crop ? crop.h : Math.round(root.selectionRect.h)
      return strings.t("context.region")
        .arg(Commons.I18n.formatNumber(w))
        .arg(Commons.I18n.formatNumber(h))
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
    id: handoffProc
    stdinEnabled: true
    command: ["/usr/bin/python3", root.pluginDir + "/scripts/actions.py", "prepare-handoff", "-"]
    onStarted: handoffProc.write(root.pendingHandoffJson + "\n")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var res = null
        try { res = JSON.parse(text) } catch (e) { res = null }
        if (res && res.ok && res.prompt) {
          // Match Omarchy's first-party agents panel: detach via login shell so
          // uwsm-app / xdg-terminal-exec / foot inherit the full desktop session.
          Util.execArgv(["omarchy-agent-prompt", res.prompt])
        }
        root.dismiss()
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
            promptField.text = promptField.text.trim()
              ? (promptField.text.trim() + " " + transcript)
              : transcript
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
    WlrLayershell.namespace: "carlos-screenlens"

    onWidthChanged: if (root.rawOcrWords.length > 0) root.remapOcrWords()
    onHeightChanged: if (root.rawOcrWords.length > 0) root.remapOcrWords()

    // Four dim strips framing the selected region so the cutout stays crystal-clear.
    // Leaving the unselected surface un-tinted keeps the live screen crisp and
    // avoids fullscreen opaque-region quirks on Wayland layer-shell surfaces.
    Item {
      anchors.fill: parent
      visible: !!root.selectionRect
      readonly property real rx: root.selectionRect ? root.selectionRect.x : 0
      readonly property real ry: root.selectionRect ? root.selectionRect.y : 0
      readonly property real rw: root.selectionRect ? root.selectionRect.w : 0
      readonly property real rh: root.selectionRect ? root.selectionRect.h : 0

      Rectangle { x: 0; y: 0; width: parent.width; height: Math.max(0, parent.ry); color: Qt.rgba(0, 0, 0, 0.44) }
      Rectangle { x: 0; y: parent.ry + parent.rh; width: parent.width; height: Math.max(0, parent.height - (parent.ry + parent.rh)); color: Qt.rgba(0, 0, 0, 0.44) }
      Rectangle { x: 0; y: parent.ry; width: Math.max(0, parent.rx); height: parent.rh; color: Qt.rgba(0, 0, 0, 0.44) }
      Rectangle { x: parent.rx + parent.rw; y: parent.ry; width: Math.max(0, parent.width - (parent.rx + parent.rw)); height: parent.rh; color: Qt.rgba(0, 0, 0, 0.44) }

      // Accent frame + corner ticks around selected region.
      Rectangle {
        x: parent.rx
        y: parent.ry
        width: parent.rw
        height: parent.rh
        color: "transparent"
        border.width: 2
        border.color: root.accentColor

        readonly property real tick: Math.min(14, width / 3, height / 3)
        Rectangle { x: 0; y: 0; width: parent.tick; height: 4; color: root.accentColor }
        Rectangle { x: 0; y: 0; width: 4; height: parent.tick; color: root.accentColor }
        Rectangle { x: parent.width - parent.tick; y: 0; width: parent.tick; height: 4; color: root.accentColor }
        Rectangle { x: parent.width - 4; y: 0; width: 4; height: parent.tick; color: root.accentColor }
        Rectangle { x: 0; y: parent.height - 4; width: parent.tick; height: 4; color: root.accentColor }
        Rectangle { x: 0; y: parent.height - parent.tick; width: 4; height: parent.tick; color: root.accentColor }
        Rectangle { x: parent.width - parent.tick; y: parent.height - 4; width: parent.tick; height: 4; color: root.accentColor }
        Rectangle { x: parent.width - 4; y: parent.height - parent.tick; width: 4; height: parent.tick; color: root.accentColor }
      }
    }

    // Subtle edge glow so the user feels ScreenLens activate immediately.
    Rectangle {
      anchors.fill: parent
      color: "transparent"
      border.width: Math.max(2, Style.space(3))
      border.color: Util.alpha(root.accentColor, 0.72)
      opacity: root.opened ? 1 : 0
      Behavior on opacity {
        NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
      }
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
          radius: 2
          color: isSelected
            ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.42)
            : Qt.rgba(1, 1, 1, 0.14)
          border.width: isSelected ? 1 : 0
          border.color: root.accentColor
        }
      }
    }

    // Native GPU-rendered freehand lasso stroke while dragging.
    Shape {
      anchors.fill: parent
      visible: root.draggingCanvas && root.mode === "lasso" && root.lassoPathPoints.length > 1
      antialiasing: true

      ShapePath {
        fillColor: "transparent"
        strokeColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.35)
        strokeWidth: 10
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        PathPolyline { path: root.lassoPathPoints }
      }

      ShapePath {
        fillColor: "transparent"
        strokeColor: root.accentColor
        strokeWidth: 3
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

      Row {
        id: selectionRow
        anchors.centerIn: parent
        spacing: Style.spacing.xs

        Ui.Button {
          visible: root.selectedText.length > 0
          text: strings.t("action.copyText")
          iconText: "󰆏"
          onClicked: root.copyText(root.selectedText)
        }

        Ui.Button {
          visible: !!root.selectionRect
          text: strings.t("chip.extractText")
          iconText: "󰗧"
          onClicked: root.extractAndCopyText()
        }

        Ui.Button {
          visible: !!root.selectionRect
          text: strings.t("action.copy")
          iconText: "󰋩"
          onClicked: root.copySelectedImage()
        }

        Ui.Button {
          text: strings.t("action.askSelection")
          iconText: "󰚩"
          selected: true
          onClicked: root.runQuickChip("explain")
        }

        Ui.Button {
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
      anchors.topMargin: Math.max(Style.gapsOut, Style.space(14))
      anchors.horizontalCenter: parent.horizontalCenter
      color: root.bgColor
      borderSpec: root.cardBorderSpec
      radius: root.cornerRadius
      padding: Style.spacing.xs
      implicitWidth: topRow.implicitWidth + padding * 2 + Border.left(borderSpec) + Border.right(borderSpec)
      implicitHeight: topRow.implicitHeight + padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.97
      Behavior on opacity { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: Style.duration(180); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }

      MouseArea { anchors.fill: parent; onClicked: {} }

      Row {
        id: topRow
        anchors.centerIn: parent
        spacing: Style.spacing.xs

        Ui.Button {
          text: strings.t("mode.lasso")
          iconText: "󰒅"
          selected: root.mode === "lasso"
          onClicked: {
            root.mode = "lasso"
            promptField.forceActiveFocus()
          }
        }

        Ui.Button {
          text: strings.t("mode.text")
          iconText: "󰗧"
          iconSpinning: root.ocrLoading
          selected: root.mode === "text"
          onClicked: {
            root.mode = "text"
            promptField.forceActiveFocus()
          }
        }

        Ui.Button {
          text: strings.t("mode.fullScreen")
          iconText: "󰊓"
          visible: !!root.selectionRect || root.selectedText.length > 0
          onClicked: root.clearSelection()
        }

        Rectangle {
          width: 1
          height: Style.space(18)
          anchors.verticalCenter: parent.verticalCenter
          color: Util.alpha(root.fgColor, 0.2)
        }

        PlainText {
          anchors.verticalCenter: parent.verticalCenter
          leftPadding: Style.spacing.xs
          rightPadding: Style.spacing.xs
          text: root.ocrLoading
            ? strings.t("hint.ocrLoading")
            : (root.mode === "text"
                ? (root.ocrWords.length > 0
                    ? strings.tn("hint.ocrReady", root.ocrWords.length).arg(Commons.I18n.formatNumber(root.ocrWords.length))
                    : strings.t("hint.ocrEmpty"))
                : strings.t("hint.lasso"))
          color: Util.alpha(root.fgColor, 0.72)
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
        }

        Ui.Button {
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

      // Toast strip
      Ui.BorderSurface {
        visible: root.toastMessage.length > 0
        anchors.horizontalCenter: parent.horizontalCenter
        color: root.bgColor
        borderSpec: root.cardBorderSpec
        radius: root.cornerRadius
        padding: Style.spacing.xs
        implicitWidth: toastLabel.implicitWidth + Style.spacing.md * 2
        implicitHeight: toastLabel.implicitHeight + Style.spacing.xs * 2

        PlainText {
          id: toastLabel
          anchors.centerIn: parent
          text: root.toastMessage
          color: root.accentColor
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
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
        readonly property real maxBodyHeight: Math.min(panel.height * 0.42, Style.space(420))
        implicitHeight: answerHeader.implicitHeight
          + Math.min(maxBodyHeight, Math.max(Style.space(44), answerColumn.implicitHeight + Style.spacing.sm))
          + Style.spacing.panelPadding * 2
          + Style.spacing.sm
          + Border.top(borderSpec) + Border.bottom(borderSpec)

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
              spacing: Style.spacing.xs

              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: "󰚩"
                color: root.accentColor
                font.family: root.uiFont
                font.pixelSize: Style.font.icon
              }

              PlainText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.providerLabel || strings.t("app.title")
                color: Util.alpha(root.fgColor, 0.78)
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              PlainText {
                visible: root.streaming
                anchors.verticalCenter: parent.verticalCenter
                text: "· " + strings.t("status.thinking")
                color: root.accentColor
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              id: answerActionRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.xs

              Ui.Button {
                visible: root.latestAssistantText().length > 0
                text: strings.t("action.copy")
                iconText: "󰆏"
                fontSize: Style.font.bodySmall
                onClicked: root.copyText(root.latestAssistantText())
              }

              Ui.Button {
                text: strings.t("action.handoff")
                iconText: "󰆍"
                fontSize: Style.font.bodySmall
                bordered: true
                onClicked: root.handoffToAgent()
              }

              Ui.Button {
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
              width: answerScroll.width - Style.space(8)
              spacing: Style.spacing.sm

              Repeater {
                model: root.messages
                delegate: Rectangle {
                  width: answerColumn.width
                  radius: Math.min(4, root.cornerRadius)
                  color: modelData.role === "user"
                    ? Util.alpha(root.accentColor, 0.14)
                    : Util.alpha(root.fgColor, 0.05)
                  implicitHeight: msgText.implicitHeight + Style.spacing.sm * 2

                  PlainText {
                    id: msgText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.spacing.sm
                    text: modelData.text
                    color: modelData.role === "user" ? root.accentColor : root.fgColor
                    font.family: root.uiFont
                    font.pixelSize: Style.font.body
                    font.bold: modelData.role === "user"
                    wrapMode: Text.Wrap
                  }
                }
              }

              // Active streaming chunk
              Rectangle {
                visible: root.streaming && root.streamingText.length > 0
                width: answerColumn.width
                radius: Math.min(4, root.cornerRadius)
                color: Util.alpha(root.fgColor, 0.05)
                implicitHeight: streamText.implicitHeight + Style.spacing.sm * 2

                PlainText {
                  id: streamText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.spacing.sm
                  text: root.streamingText
                  color: root.fgColor
                  font.family: root.uiFont
                  font.pixelSize: Style.font.body
                  wrapMode: Text.Wrap
                }
              }

              // Inline error box
              Rectangle {
                visible: root.errorMessage.length > 0
                width: answerColumn.width
                radius: Math.min(4, root.cornerRadius)
                color: Util.alpha(root.urgentColor, 0.18)
                border.width: 1
                border.color: Util.alpha(root.urgentColor, 0.6)
                implicitHeight: errText.implicitHeight + Style.spacing.sm * 2

                PlainText {
                  id: errText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.spacing.sm
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

      // Quick-action chips row
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.spacing.xs

        Ui.Button {
          text: strings.t("chip.explain")
          iconText: "󰋗"
          background: root.bgColor
          bordered: true
          fontSize: Style.font.bodySmall
          onClicked: root.runQuickChip("explain")
        }

        Ui.Button {
          text: strings.t("chip.summarize")
          iconText: "󰦨"
          background: root.bgColor
          bordered: true
          fontSize: Style.font.bodySmall
          onClicked: root.runQuickChip("summarize")
        }

        Ui.Button {
          text: strings.t("chip.translate")
          iconText: "󰗊"
          background: root.bgColor
          bordered: true
          fontSize: Style.font.bodySmall
          onClicked: root.runQuickChip("translate")
        }

        Ui.Button {
          text: strings.t("chip.extractText")
          iconText: "󰗧"
          background: root.bgColor
          bordered: true
          fontSize: Style.font.bodySmall
          onClicked: root.runQuickChip("extract")
        }
      }

      // Main floating prompt bar
      Ui.BorderSurface {
        id: promptBar
        width: parent.width
        color: root.bgColor
        borderSpec: root.cardBorderSpec
        radius: root.cornerRadius
        padding: Style.spacing.sm
        implicitHeight: promptColumn.implicitHeight + padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
          id: promptColumn
          anchors.fill: parent
          anchors.topMargin: promptBar.contentTopInset
          anchors.rightMargin: promptBar.contentRightInset
          anchors.bottomMargin: promptBar.contentBottomInset
          anchors.leftMargin: promptBar.contentLeftInset
          spacing: Style.spacing.xs

          // Context & voice status strip
          Row {
            width: parent.width
            spacing: Style.spacing.xs

            Rectangle {
              radius: Math.min(4, root.cornerRadius)
              color: Util.alpha(root.accentColor, 0.16)
              height: ctxLabel.implicitHeight + Style.space(6)
              width: ctxLabel.implicitWidth + Style.space(14)

              PlainText {
                id: ctxLabel
                anchors.centerIn: parent
                text: root.contextBadgeText()
                color: root.accentColor
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            PlainText {
              visible: root.voiceState !== "idle"
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
              id: sendBtn
              anchors.verticalCenter: parent.verticalCenter
              text: root.streaming ? strings.t("prompt.stop") : strings.t("prompt.send")
              iconText: root.streaming ? "󰓛" : "󰁕"
              selected: !root.streaming
              bordered: true
              onClicked: {
                if (root.streaming) root.cancelStreaming()
                else root.submitPrompt()
              }
            }

            Ui.Button {
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
