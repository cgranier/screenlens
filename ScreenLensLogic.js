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
