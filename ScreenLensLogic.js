.pragma library

var MAX_TEXT_CHARS = 16000
var MAX_HANDOFF_HISTORY = 8

// Neutralizes markup-shaped characters before handing dynamic strings to any
// external component, tooltip, or notification sink outside PlainText.
function neutralizeMarkup(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

function clamp(value, minVal, maxVal) {
  if (value < minVal) return minVal
  if (value > maxVal) return maxVal
  return value
}

// Computes a padded logical bounding box from freehand lasso points or a
// two-point drag, clamped to the overlay bounds. Returns null if the drag
// was too small to count as an intentional selection.
function computeSelectionRect(points, overlayWidth, overlayHeight, padding) {
  if (!Array.isArray(points) || points.length < 2) return null
  if (!(overlayWidth > 0) || !(overlayHeight > 0)) return null

  var pad = typeof padding === "number" ? padding : 8
  var minX = Infinity
  var minY = Infinity
  var maxX = -Infinity
  var maxY = -Infinity

  for (var i = 0; i < points.length; i++) {
    var pt = points[i]
    if (!pt || !isFinite(pt.x) || !isFinite(pt.y)) continue
    if (pt.x < minX) minX = pt.x
    if (pt.y < minY) minY = pt.y
    if (pt.x > maxX) maxX = pt.x
    if (pt.y > maxY) maxY = pt.y
  }

  if (!isFinite(minX) || !isFinite(minY)) return null

  var rawW = maxX - minX
  var rawH = maxY - minY
  if (rawW < 12 && rawH < 12) return null

  var x = Math.round(clamp(minX - pad, 0, overlayWidth))
  var y = Math.round(clamp(minY - pad, 0, overlayHeight))
  var x2 = Math.round(clamp(maxX + pad, 0, overlayWidth))
  var y2 = Math.round(clamp(maxY + pad, 0, overlayHeight))
  var w = x2 - x
  var h = y2 - y

  if (w < 8 || h < 8) return null
  return { x: x, y: y, w: w, h: h }
}

// Computes an exact corner-to-corner bounding box rectangle for Box selection
// mode, clamped to overlay bounds with zero extra padding.
function computeBoxRect(x1, y1, x2, y2, overlayWidth, overlayHeight, minSize) {
  if (!isFinite(x1) || !isFinite(y1) || !isFinite(x2) || !isFinite(y2)) return null
  if (!(overlayWidth > 0) || !(overlayHeight > 0)) return null

  var minDim = typeof minSize === "number" ? Math.max(1, minSize) : 8
  var cx1 = clamp(x1, 0, overlayWidth)
  var cy1 = clamp(y1, 0, overlayHeight)
  var cx2 = clamp(x2, 0, overlayWidth)
  var cy2 = clamp(y2, 0, overlayHeight)

  var x = Math.round(Math.min(cx1, cx2))
  var y = Math.round(Math.min(cy1, cy2))
  var xEnd = Math.round(Math.max(cx1, cx2))
  var yEnd = Math.round(Math.max(cy1, cy2))
  var w = xEnd - x
  var h = yEnd - y

  if (w < minDim || h < minDim) return null
  return { x: x, y: y, w: w, h: h }
}

// Hit-tests a locked crop rectangle for corner resize handles ("nw","ne","sw","se"),
// edge resize handles ("n","s","e","w"), interior drag ("move"), or outside ("").
function hitTestCropHandle(rect, px, py, handleMargin) {
  if (!rect || !(rect.w > 0) || !(rect.h > 0)) return ""
  if (!isFinite(px) || !isFinite(py)) return ""

  var margin = typeof handleMargin === "number" ? handleMargin : 12
  var cornerTol = Math.max(8, Math.min(margin, Math.max(8, Math.min(rect.w, rect.h) * 0.4)))
  var edgeTol = Math.max(6, Math.min(9, cornerTol))

  var left = rect.x
  var top = rect.y
  var right = rect.x + rect.w
  var bottom = rect.y + rect.h

  // 1. Corner handles take priority over edges and interior.
  if (Math.abs(px - left) <= cornerTol && Math.abs(py - top) <= cornerTol) return "nw"
  if (Math.abs(px - right) <= cornerTol && Math.abs(py - top) <= cornerTol) return "ne"
  if (Math.abs(px - left) <= cornerTol && Math.abs(py - bottom) <= cornerTol) return "sw"
  if (Math.abs(px - right) <= cornerTol && Math.abs(py - bottom) <= cornerTol) return "se"

  // 2. Edge handles along the border segments.
  if (px >= left - edgeTol && px <= right + edgeTol) {
    if (Math.abs(py - top) <= edgeTol) return "n"
    if (Math.abs(py - bottom) <= edgeTol) return "s"
  }
  if (py >= top - edgeTol && py <= bottom + edgeTol) {
    if (Math.abs(px - left) <= edgeTol) return "w"
    if (Math.abs(px - right) <= edgeTol) return "e"
  }

  // 3. Interior drag to reposition.
  if (px >= left && px <= right && py >= top && py <= bottom) return "move"
  return ""
}

// Hit-tests an array of pinned crop regions from topmost (last) to bottommost.
function hitTestRegions(regions, px, py, handleMargin) {
  if (!Array.isArray(regions) || regions.length === 0) return { index: -1, handle: "" }
  for (var i = regions.length - 1; i >= 0; i--) {
    var h = hitTestCropHandle(regions[i], px, py, handleMargin)
    if (h) return { index: i, handle: h }
  }
  return { index: -1, handle: "" }
}

// Applies a move or resize drag delta to startRect, clamped cleanly inside
// [0..overlayWidth, 0..overlayHeight] with minimum logical size minSize (default 16).
function applyCropDrag(startRect, handle, dx, dy, overlayWidth, overlayHeight, minSize) {
  if (!startRect || !handle) return startRect
  if (!(overlayWidth > 0) || !(overlayHeight > 0)) return startRect

  var minDim = typeof minSize === "number" ? Math.max(8, minSize) : 16
  var maxW = Math.min(minDim, overlayWidth)
  var maxH = Math.min(minDim, overlayHeight)

  if (handle === "move") {
    var w = Math.min(startRect.w, overlayWidth)
    var h = Math.min(startRect.h, overlayHeight)
    var nx = Math.round(clamp(startRect.x + dx, 0, Math.max(0, overlayWidth - w)))
    var ny = Math.round(clamp(startRect.y + dy, 0, Math.max(0, overlayHeight - h)))
    return { x: nx, y: ny, w: Math.round(w), h: Math.round(h) }
  }

  var left = startRect.x
  var top = startRect.y
  var right = startRect.x + startRect.w
  var bottom = startRect.y + startRect.h

  if (handle.indexOf("w") !== -1) {
    left = clamp(startRect.x + dx, 0, right - maxW)
  }
  if (handle.indexOf("e") !== -1) {
    right = clamp(startRect.x + startRect.w + dx, left + maxW, overlayWidth)
  }
  if (handle.indexOf("n") !== -1) {
    top = clamp(startRect.y + dy, 0, bottom - maxH)
  }
  if (handle.indexOf("s") !== -1) {
    bottom = clamp(startRect.y + startRect.h + dy, top + maxH, overlayHeight)
  }

  var rx = Math.round(left)
  var ry = Math.round(top)
  var rw = Math.max(Math.round(maxW), Math.round(right - left))
  var rh = Math.max(Math.round(maxH), Math.round(bottom - top))
  return { x: rx, y: ry, w: rw, h: rh }
}

// Maps a logical overlay rectangle into physical screenshot pixels for cropping.
function logicalToImageRect(rect, overlayWidth, overlayHeight, imageWidth, imageHeight) {
  if (!rect) return null
  if (!(overlayWidth > 0) || !(overlayHeight > 0)) return null
  if (!(imageWidth > 0) || !(imageHeight > 0)) return null

  var sx = imageWidth / overlayWidth
  var sy = imageHeight / overlayHeight

  var x = Math.round(clamp(rect.x * sx, 0, imageWidth - 1))
  var y = Math.round(clamp(rect.y * sy, 0, imageHeight - 1))
  var x2 = Math.round(clamp((rect.x + rect.w) * sx, x + 1, imageWidth))
  var y2 = Math.round(clamp((rect.y + rect.h) * sy, y + 1, imageHeight))

  return { x: x, y: y, w: x2 - x, h: y2 - y }
}

// Converts OCR word boxes from image pixel space into logical overlay space.
function mapWordsToOverlay(words, imageWidth, imageHeight, overlayWidth, overlayHeight) {
  if (!Array.isArray(words) || words.length === 0) return []
  if (!(imageWidth > 0) || !(imageHeight > 0) || !(overlayWidth > 0) || !(overlayHeight > 0)) return []

  var sx = overlayWidth / imageWidth
  var sy = overlayHeight / imageHeight
  var out = []

  for (var i = 0; i < words.length; i++) {
    var w = words[i]
    if (!w || typeof w.text !== "string" || !w.text.length) continue
    out.push({
      index: out.length,
      text: w.text,
      x: w.x * sx,
      y: w.y * sy,
      w: Math.max(2, w.w * sx),
      h: Math.max(2, w.h * sy),
      lineKey: String(w.block || 0) + ":" + String(w.par || 0) + ":" + String(w.line || 0)
    })
  }
  return out
}

// Finds the word directly under (px, py), or the closest word within maxDist.
function hitTestWord(words, px, py, maxDist) {
  if (!Array.isArray(words) || words.length === 0) return -1
  var limit = typeof maxDist === "number" ? maxDist : 28
  var bestIdx = -1
  var bestDistSq = limit * limit

  for (var i = 0; i < words.length; i++) {
    var w = words[i]
    if (px >= w.x && px <= w.x + w.w && py >= w.y && py <= w.y + w.h) {
      return i
    }
    var cx = clamp(px, w.x, w.x + w.w)
    var cy = clamp(py, w.y, w.y + w.h)
    var dx = px - cx
    var dy = py - cy
    var distSq = dx * dx + dy * dy
    if (distSq < bestDistSq) {
      bestDistSq = distSq
      bestIdx = i
    }
  }
  return bestIdx
}

// Selects words either by reading-order range [startIdx..endIdx] when the drag
// starts and ends on words, or by bounding-box intersection fallback.
function selectWordsBetween(words, startIdx, endIdx, dragRect) {
  if (!Array.isArray(words) || words.length === 0) {
    return { indices: [], text: "", bounds: null }
  }

  var indices = []
  if (startIdx >= 0 && endIdx >= 0) {
    var lo = Math.min(startIdx, endIdx)
    var hi = Math.max(startIdx, endIdx)
    for (var i = lo; i <= hi; i++) indices.push(i)
  } else if (dragRect) {
    var rx2 = dragRect.x + dragRect.w
    var ry2 = dragRect.y + dragRect.h
    for (var j = 0; j < words.length; j++) {
      var w = words[j]
      var overlaps = !(w.x + w.w < dragRect.x || w.x > rx2 || w.y + w.h < dragRect.y || w.y > ry2)
      if (overlaps) indices.push(j)
    }
  }

  return formatSelectedWords(words, indices)
}

// Extracts OCR words whose center points fall inside rect (with a 2 px margin)
// in reading order with line breaks preserved. Enables 0 ms Extract Text when
// full-screen OCR has already completed.
function extractWordsInRect(words, rect) {
  if (!Array.isArray(words) || words.length === 0 || !rect) {
    return { indices: [], text: "", bounds: null }
  }
  var x1 = rect.x - 2
  var y1 = rect.y - 2
  var x2 = rect.x + rect.w + 2
  var y2 = rect.y + rect.h + 2
  var indices = []
  for (var i = 0; i < words.length; i++) {
    var w = words[i]
    if (!w) continue
    var cx = w.x + w.w * 0.5
    var cy = w.y + w.h * 0.5
    if (cx >= x1 && cx <= x2 && cy >= y1 && cy <= y2) {
      indices.push(i)
    }
  }
  return formatSelectedWords(words, indices)
}

function formatSelectedWords(words, indices) {
  if (!Array.isArray(indices) || indices.length === 0) {
    return { indices: [], text: "", bounds: null }
  }

  var parts = []
  var prevLine = null
  var minX = Infinity
  var minY = Infinity
  var maxX = -Infinity
  var maxY = -Infinity

  for (var i = 0; i < indices.length; i++) {
    var w = words[indices[i]]
    if (!w) continue
    if (prevLine !== null) {
      parts.push(w.lineKey !== prevLine ? "\n" : " ")
    }
    parts.push(w.text)
    prevLine = w.lineKey

    if (w.x < minX) minX = w.x
    if (w.y < minY) minY = w.y
    if (w.x + w.w > maxX) maxX = w.x + w.w
    if (w.y + w.h > maxY) maxY = w.y + w.h
  }

  var text = parts.join("").slice(0, MAX_TEXT_CHARS)
  var bounds = isFinite(minX) ? { x: minX, y: minY, w: maxX - minX, h: maxY - minY } : null
  return { indices: indices, text: text, bounds: bounds }
}

// Resolves the active surface palette for "system" | "dark" | "light" theme
// overrides while always preserving the live Omarchy accent and urgent colors.
function resolveThemePalette(themeMode, systemPalette) {
  var sys = systemPalette || ({})
  var mode = String(themeMode || "system").toLowerCase()
  if (mode === "dark") {
    return {
      background: "#181a22",
      text: "#e6e9f2",
      border: "#353b4d",
      scrim: "#7a000000",
      accent: sys.accent || "#7aa2f7",
      urgent: sys.urgent || "#f7768e"
    }
  }
  if (mode === "light") {
    return {
      background: "#f5f6fa",
      text: "#1b1f2a",
      border: "#c7cddb",
      scrim: "#520f1420",
      accent: sys.accent || "#7aa2f7",
      urgent: sys.urgent || "#d6455d"
    }
  }
  return {
    background: sys.background || "#101315",
    text: sys.text || "#cacccc",
    border: sys.border || "#cacccc",
    scrim: sys.scrim || "#70101315",
    accent: sys.accent || "#7aa2f7",
    urgent: sys.urgent || "#a55555"
  }
}

// Builds a clear, structured prompt for handing the session off to
// `omarchy agent prompt` so the user's coding agent has full visual & text context.
function buildAgentHandoffPrompt(opts) {
  var lines = []
  lines.push("Context captured via ScreenLens:")

  if (opts && opts.windowClass) {
    var winLabel = opts.windowTitle
      ? opts.windowClass + " — " + opts.windowTitle
      : opts.windowClass
    lines.push("- Active window: " + winLabel)
  }

  if (opts && opts.imagePath) {
    lines.push("- Screenshot file: " + opts.imagePath)
  }

  if (opts && opts.crop) {
    lines.push("- Selected region (image px): x=" + opts.crop.x + ", y=" + opts.crop.y + ", w=" + opts.crop.w + ", h=" + opts.crop.h)
  }

  if (opts && opts.selectedText) {
    lines.push("")
    lines.push("Selected on-screen text:")
    lines.push('"""')
    lines.push(String(opts.selectedText).slice(0, 4000))
    lines.push('"""')
  }

  if (opts && Array.isArray(opts.messages) && opts.messages.length > 0) {
    var recent = opts.messages.slice(-MAX_HANDOFF_HISTORY)
    lines.push("")
    lines.push("Prior ScreenLens conversation:")
    for (var i = 0; i < recent.length; i++) {
      var msg = recent[i]
      if (!msg || !msg.text) continue
      var role = msg.role === "user" ? "User" : "Assistant"
      lines.push(role + ": " + String(msg.text).slice(0, 2000))
    }
  }

  if (opts && opts.draftPrompt && String(opts.draftPrompt).trim().length > 0) {
    lines.push("")
    lines.push("Follow-up request: " + String(opts.draftPrompt).trim())
  } else {
    lines.push("")
    lines.push("Continue helping me with what is shown above. Inspect the screenshot file if helpful.")
  }

  return lines.join("\n")
}

function _normWhitespace(value) {
  return String(value === undefined || value === null ? "" : value).trim().replace(/\s+/g, " ")
}

function _countOccurrences(haystack, needle) {
  if (!haystack || !needle) return 0
  var count = 0
  var pos = 0
  while (true) {
    var idx = haystack.indexOf(needle, pos)
    if (idx === -1) break
    count++
    pos = idx + needle.length
  }
  return count
}

// Merges a Superwhisper voice transcript into the prompt field without
// duplicating it when Superwhisper's auto-paste / Wayland text-commit has
// already inserted the transcript into the focused input.
function mergeVoiceTranscript(beforeText, currentText, transcript) {
  var before = String(beforeText || "")
  var current = String(currentText || "")
  var clean = String(transcript || "").trim()
  if (!clean) return current

  var normClean = _normWhitespace(clean)
  if (current !== before) {
    var beforeCount = _countOccurrences(_normWhitespace(before), normClean)
    var currentCount = _countOccurrences(_normWhitespace(current), normClean)
    if (currentCount > beforeCount) {
      return current
    }
  }

  var trimmedCurrent = current.trim()
  return trimmedCurrent ? (trimmedCurrent + " " + clean) : clean
}

// Collapses an immediate late auto-paste duplicate if Superwhisper commits the
// same transcript into the focused field right after ScreenLens inserted it.
function dedupeLateVoicePaste(currentText, expectedAfterInsert, transcript) {
  var current = String(currentText || "")
  var expected = String(expectedAfterInsert || "")
  var clean = String(transcript || "").trim()
  if (!current || !expected || !clean || current === expected) return current

  var normCurrent = _normWhitespace(current)
  var normExpected = _normWhitespace(expected)
  var normClean = _normWhitespace(clean)
  if (_countOccurrences(normCurrent, normClean) <= _countOccurrences(normExpected, normClean)) {
    return current
  }

  // Strip one extra occurrence of the transcript (adjacent with or without space)
  // and verify the remaining text matches what ScreenLens expected.
  var idx = normCurrent.lastIndexOf(normClean)
  if (idx !== -1) {
    var candidate = _normWhitespace(normCurrent.slice(0, idx) + " " + normCurrent.slice(idx + normClean.length))
    if (candidate === normExpected) {
      return expected
    }
  }
  return current
}

// Picks high-contrast foreground ink for a hex color (e.g. text over accent fills).
function inkOn(hexColor) {
  var s = String(hexColor || "").trim()
  var m = s.match(/^#([0-9a-fA-F]{6})/)
  if (!m) return "#101315"
  var hex = m[1]
  var r = parseInt(hex.slice(0, 2), 16) / 255
  var g = parseInt(hex.slice(2, 4), 16) / 255
  var b = parseInt(hex.slice(4, 6), 16) / 255
  var lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
  return lum > 0.52 ? "#101315" : "#f5f6fa"
}

// Strips inline markdown markers (**bold**, __bold__, `code`) cleanly so
// PlainText blocks never show raw asterisks while preserving readable prose.
function stripInlineMarkdown(text) {
  var s = String(text || "")
  s = s.replace(/\*\*([^*\n]+)\*\*/g, "$1")
  s = s.replace(/__([^_\n]+)__/g, "$1")
  s = s.replace(/`([^`\n]+)`/g, "$1")
  return s
}

// Parses assistant output into PlainText-safe visual blocks (headings, bold
// subheadings, bullets, fenced code cards, and paragraphs) without ever using
// RichText/HTML. Handles partially streamed unclosed code fences gracefully.
function parseAnswerBlocks(rawText) {
  var src = String(rawText || "").replace(/\r\n/g, "\n")
  if (!src.trim()) return []

  var lines = src.split("\n")
  var blocks = []
  var inCode = false
  var codeLang = ""
  var codeLines = []
  var paraLines = []

  function flushPara() {
    if (paraLines.length === 0) return
    var joined = stripInlineMarkdown(paraLines.join("\n")).trim()
    if (joined) blocks.push({ kind: "paragraph", lang: "", text: joined })
    paraLines = []
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var fence = line.match(/^\s*```([A-Za-z0-9_+#.-]*)\s*$/)
    if (fence) {
      if (!inCode) {
        flushPara()
        inCode = true
        codeLang = (fence[1] || "").trim()
        codeLines = []
      } else {
        blocks.push({ kind: "code", lang: codeLang, text: codeLines.join("\n") })
        inCode = false
        codeLang = ""
        codeLines = []
      }
      continue
    }

    if (inCode) {
      codeLines.push(line)
      continue
    }

    var trimmed = line.trim()
    if (!trimmed) {
      flushPara()
      continue
    }

    var heading = trimmed.match(/^#{1,4}\s+(.+)$/)
    if (heading) {
      flushPara()
      blocks.push({ kind: "heading", lang: "", text: stripInlineMarkdown(heading[1]).trim() })
      continue
    }

    // Standalone **Bold line** (e.g. "**Drop these in order of preference:**")
    var boldLine = trimmed.match(/^\*\*([^*\n]+)\*\*$/)
    if (boldLine) {
      flushPara()
      blocks.push({ kind: "subheading", lang: "", text: boldLine[1].trim() })
      continue
    }

    var bullet = line.match(/^\s*(?:[-*•]|(\d+)\.)\s+(.+)$/)
    if (bullet) {
      flushPara()
      blocks.push({
        kind: "bullet",
        lang: bullet[1] ? (bullet[1] + ".") : "•",
        text: stripInlineMarkdown(bullet[2]).trim()
      })
      continue
    }

    paraLines.push(line)
  }

  if (inCode) {
    blocks.push({ kind: "code", lang: codeLang, text: codeLines.join("\n") })
  } else {
    flushPara()
  }

  return blocks
}
