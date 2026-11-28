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

// Validates that a string is a safe http:// or https:// web URL (rejects
// javascript:, file:, data:, mailto:, whitespace, or control chars).
function isSafeHttpUrl(raw) {
  var s = String(raw || "").trim()
  if (!s || s.length > 2048) return false
  if (/[\s\x00-\x1f\x7f]/.test(s)) return false
  var m = s.match(/^(https?):\/\/([^\/?#]+)(?:[\/?#].*)?$/i)
  if (!m) return false
  var host = m[2]
  return host.length > 0 && host.indexOf(".") !== -1
}

// Converts decoded QR/barcode bounding boxes from image pixel space into
// logical overlay coordinates.
function mapCodesToOverlay(codes, imageWidth, imageHeight, overlayWidth, overlayHeight) {
  if (!Array.isArray(codes) || codes.length === 0) return []
  if (!(imageWidth > 0) || !(imageHeight > 0) || !(overlayWidth > 0) || !(overlayHeight > 0)) return []

  var sx = overlayWidth / imageWidth
  var sy = overlayHeight / imageHeight
  var out = []

  for (var i = 0; i < codes.length; i++) {
    var c = codes[i]
    if (!c || typeof c.data !== "string" || !c.data.trim().length) continue
    var data = c.data.trim()
    out.push({
      type: String(c.type || "QR-Code"),
      data: data,
      isUrl: !!(c.isUrl && isSafeHttpUrl(data)),
      x: (Number(c.x) || 0) * sx,
      y: (Number(c.y) || 0) * sy,
      w: Math.max(2, (Number(c.w) || 0) * sx),
      h: Math.max(2, (Number(c.h) || 0) * sy)
    })
  }
  return out
}

function _rectContainsCenter(rect, item, pad) {
  if (!rect || !item) return false
  var p = typeof pad === "number" ? pad : 4
  var cx = item.x + item.w * 0.5
  var cy = item.y + item.h * 0.5
  return cx >= rect.x - p && cx <= rect.x + rect.w + p && cy >= rect.y - p && cy <= rect.y + rect.h + p
}

function _rectOverlaps(a, b) {
  if (!a || !b) return false
  return !(a.x + a.w < b.x || a.x > b.x + b.w || a.y + a.h < b.y || a.y > b.y + b.h)
}

// Detects error banners, stack traces, compiler/runtime failures, and HTTP 4xx/5xx diagnostics.
function detectErrorSignal(text, windowClass) {
  var src = String(text || "")
  if (src.trim().length < 6) return false

  var score = 0
  var strong = [
    /Traceback\s*\(most recent call last\)/i,
    /\b(?:TypeError|ReferenceError|SyntaxError|ValueError|KeyError|AttributeError|IndexError|RuntimeError|NameError|ImportError|ModuleNotFoundError|AssertionError|NullPointerException|Segfault|Segmentation fault)\b/,
    /\b(?:SIGSEGV|SIGABRT|SIGBUS|SIGKILL|ENOENT|EACCES|ECONNREFUSED)\b/,
    /\bpanic:\s/i,
    /\bFATAL\b/,
    /\bUnhandledPromiseRejection\b/,
    /\b(?:exit(?:ed)?(?:\s+with)?\s+code|status)\s+[1-9]\d*\b/i,
    /\berror\[E\d+\]/i,
    /\bHTTP\s+[45]\d{2}\b/i,
    /\bPermission denied\b/i,
    /\bCannot (?:find module|read propert|assign)\b/i,
    /\bundefined reference to\b/i,
    /\bat\s+\S+\.(?:js|ts|tsx|jsx|py|rs|go|java|cpp|c|h|qml):\d+/i
  ]
  for (var i = 0; i < strong.length; i++) {
    if (strong[i].test(src)) score += 2
    if (score >= 2) return true
  }

  var medium = [
    /\berror:\s+\S/i,
    /\bexception\b/i,
    /\bstack\s*trace\b/i,
    /\bfailed\b/i,
    /\bwarning:\s+\S/i
  ]
  for (var j = 0; j < medium.length; j++) {
    if (medium[j].test(src)) score += 1
  }

  if (score >= 1) {
    var win = String(windowClass || "").toLowerCase()
    if (/ghostty|alacritty|kitty|foot|wezterm|konsole|xterm|code|cursor|zed|nvim|vim|jetbrains|idea|pycharm/.test(win)) {
      score += 1
    }
  }
  return score >= 2
}

// Detects tabular layouts from OCR word bounding boxes by extracting aligned
// vertical column tracks (left- or right-aligned), verifying a contiguous run
// of evenly spaced rows with no interleaved non-table rows (e.g. DM/inbox
// preview lines), and rejecting multi-pane prose UIs.
function detectTableLayout(words, opts) {
  if (!Array.isArray(words) || words.length < 6) return false

  var o = opts || ({})
  var hasSelection = Boolean(o.hasSelection)

  var valid = []
  var heights = []
  for (var i = 0; i < words.length; i++) {
    var w = words[i]
    if (!w || !w.text || !String(w.text).trim() || !(w.h > 0) || !(w.w > 0)) continue
    valid.push(w)
    heights.push(w.h)
  }
  if (valid.length < 6) return false

  heights.sort(function(a, b) { return a - b })
  var medH = Math.max(8, heights[Math.floor(heights.length / 2)])
  var rowTol = Math.max(6, medH * 0.6)
  var colGap = Math.max(18, medH * 1.45)
  var alignTol = Math.max(14, medH * 1.15)
  var maxRowStep = Math.max(68, medH * 4.2)
  var maxColGutter = Math.max(260, medH * 18)

  // Strict top-to-bottom sort before clustering into visual rows.
  valid.sort(function(a, b) {
    var ay = a.y + a.h * 0.5
    var by = b.y + b.h * 0.5
    if (ay !== by) return ay - by
    return a.x - b.x
  })

  // Cluster into visual rows, preserving ALL rows (including 1-column rows so
  // interleaved preview/snippet lines in chat or inbox lists are detected).
  var allRows = []
  for (var j = 0; j < valid.length; j++) {
    var word = valid[j]
    var cy = word.y + word.h * 0.5
    var row = allRows.length > 0 ? allRows[allRows.length - 1] : null
    if (!row || Math.abs(cy - row.cy) > rowTol) {
      allRows.push({ cy: cy, words: [word] })
    } else {
      row.words.push(word)
    }
  }
  if (allRows.length < 3) return false

  // Split each row into horizontal cells and classify cell compactness/data.
  var compactCells = []
  for (var r = 0; r < allRows.length; r++) {
    var rw = allRows[r].words
    rw.sort(function(a, b) { return a.x - b.x })
    var cells = []
    var rowMinX = Infinity
    var rowMaxX2 = -Infinity
    var rowMaxWords = 0

    for (var k = 0; k < rw.length; k++) {
      var cur = rw[k]
      var prev = cells.length > 0 ? cells[cells.length - 1] : null
      if (!prev || cur.x - prev.x2 >= colGap) {
        cells.push({
          rowIdx: r,
          cy: allRows[r].cy,
          x: cur.x,
          x2: cur.x + cur.w,
          h: cur.h,
          text: String(cur.text).trim(),
          wordCount: 1
        })
      } else {
        prev.x2 = Math.max(prev.x2, cur.x + cur.w)
        prev.h = Math.max(prev.h, cur.h)
        prev.text += " " + String(cur.text).trim()
        prev.wordCount += 1
      }
      if (cur.x < rowMinX) rowMinX = cur.x
      if (cur.x + cur.w > rowMaxX2) rowMaxX2 = cur.x + cur.w
    }

    for (var c = 0; c < cells.length; c++) {
      var cell = cells[c]
      var t = cell.text
      if (cell.wordCount > rowMaxWords) rowMaxWords = cell.wordCount
      cell.isNumeric = /^[\$€£¥+\-~≈]?\d[\d,.:%\/-]*[kKmMbB%]?(?:\/(?:mo|yr|hr|s))?$/i.test(t)
      cell.isDatum = cell.isNumeric ||
        /^(?:true|false|yes|no|n\/a|ok|pass|fail|active|pending|open|closed|done)$/i.test(t) ||
        /^[A-Z]{2,5}$/.test(t)
      cell.isProse = cell.wordCount >= 6 || t.length > 38
      cell.isCompact = !cell.isProse && cell.h >= medH * 0.55 && cell.h <= medH * 1.9
      if (cell.isCompact) compactCells.push(cell)
    }

    allRows[r].cells = cells
    allRows[r].minX = rowMinX
    allRows[r].maxX2 = rowMaxX2
    allRows[r].maxWords = rowMaxWords
  }

  var minCols = hasSelection ? 2 : 3
  if (compactCells.length < minCols * 3) return false

  // Discover non-overlapping vertical column tracks (left- or right-aligned)
  // backed by >= 3 distinct rows.
  var usedCell = {}
  var tracks = []
  var safety = 0
  while (safety < 24) {
    safety++
    var bestTrack = null

    for (var ci = 0; ci < compactCells.length; ci++) {
      if (usedCell[ci]) continue
      var anchor = compactCells[ci]
      var modes = ["left", "right"]
      for (var mi = 0; mi < modes.length; mi++) {
        var mode = modes[mi]
        var anchorPos = mode === "left" ? anchor.x : anchor.x2
        var byRow = {}
        var members = []
        for (var cj = 0; cj < compactCells.length; cj++) {
          if (usedCell[cj]) continue
          var cand = compactCells[cj]
          var candPos = mode === "left" ? cand.x : cand.x2
          var diff = Math.abs(candPos - anchorPos)
          if (diff <= alignTol) {
            var prevPick = byRow[cand.rowIdx]
            if (!prevPick || diff < prevPick.diff) {
              byRow[cand.rowIdx] = { idx: cj, cell: cand, diff: diff }
            }
          }
        }
        for (var rk in byRow) {
          if (Object.prototype.hasOwnProperty.call(byRow, rk)) {
            members.push(byRow[rk])
          }
        }
        if (members.length < 3) continue
        if (!bestTrack || members.length > bestTrack.members.length) {
          bestTrack = { mode: mode, pos: anchorPos, members: members }
        }
      }
    }

    if (!bestTrack) break

    var tMinX = Infinity
    var tMaxX2 = -Infinity
    var rowMap = {}
    for (var tk = 0; tk < bestTrack.members.length; tk++) {
      var m = bestTrack.members[tk]
      usedCell[m.idx] = true
      rowMap[m.cell.rowIdx] = m.cell
      if (m.cell.x < tMinX) tMinX = m.cell.x
      if (m.cell.x2 > tMaxX2) tMaxX2 = m.cell.x2
    }

    tracks.push({
      minX: tMinX,
      maxX2: tMaxX2,
      centerX: (tMinX + tMaxX2) * 0.5,
      rowMap: rowMap
    })
  }

  if (tracks.length < minCols) return false
  tracks.sort(function(a, b) { return a.minX - b.minX })

  // Evaluate contiguous slices of column tracks for a genuine table grid.
  for (var a = 0; a < tracks.length; a++) {
    for (var b = a + minCols - 1; b < tracks.length; b++) {
      var sliceLen = b - a + 1
      var validGutters = true
      for (var p = a; p < b; p++) {
        if (tracks[p + 1].minX < tracks[p].minX + 12) { validGutters = false; break }
        if (tracks[p + 1].minX - tracks[p].maxX2 > maxColGutter) { validGutters = false; break }
      }
      if (!validGutters) break

      var gridX1 = tracks[a].minX
      var gridX2 = tracks[b].maxX2
      var minTrackHits = sliceLen === 2 ? 2 : Math.max(3, Math.ceil(sliceLen * 0.7))

      // Collect rows populated across this column slice with uniform cell height.
      var matched = []
      for (var ri = 0; ri < allRows.length; ri++) {
        var rowCells = []
        var minH = Infinity
        var maxH = 0
        for (var ti = a; ti <= b; ti++) {
          var tc = tracks[ti].rowMap[ri]
          if (tc) {
            rowCells.push({ trackOffset: ti - a, cell: tc })
            if (tc.h < minH) minH = tc.h
            if (tc.h > maxH) maxH = tc.h
          }
        }
        if (rowCells.length >= minTrackHits && minH > 0 && (maxH / minH) <= 1.75) {
          matched.push({ rowIdx: ri, cy: allRows[ri].cy, cells: rowCells })
        }
      }

      var minRowsNeeded = sliceLen === 2 ? 4 : 3
      if (matched.length < minRowsNeeded) continue

      // Split matched rows into contiguous vertical runs (no large vertical
      // jumps and no interleaved prose / non-table rows inside [gridX1, gridX2]).
      var runStart = 0
      while (runStart < matched.length) {
        var run = [matched[runStart]]
        var wrappedGaps = 0

        for (var nxt = runStart + 1; nxt < matched.length; nxt++) {
          var prevM = run[run.length - 1]
          var curM = matched[nxt]
          var dy = curM.cy - prevM.cy
          if (dy <= 0 || dy > maxRowStep) break

          // Count intervening rows in allRows overlapping this table's X-band.
          var intervening = 0
          var hasProseIntervening = false
          for (var mid = prevM.rowIdx + 1; mid < curM.rowIdx; mid++) {
            var midRow = allRows[mid]
            var overlapsGrid = !(midRow.maxX2 < gridX1 - 4 || midRow.minX > gridX2 + 4)
            if (overlapsGrid) {
              intervening++
              if (midRow.maxWords >= 4) hasProseIntervening = true
            }
          }

          if (intervening > 1 || hasProseIntervening) break
          if (intervening === 1) {
            if (sliceLen === 2) break
            wrappedGaps++
          }
          run.push(curM)
        }

        if (run.length >= minRowsNeeded) {
          var maxAllowedWrapped = Math.floor((run.length - 1) / 3)
          if (wrappedGaps <= maxAllowedWrapped) {
            // Check row-spacing regularity.
            var minDy = Infinity
            var maxDy = 0
            for (var d = 1; d < run.length; d++) {
              var step = run[d].cy - run[d - 1].cy
              if (step < minDy) minDy = step
              if (step > maxDy) maxDy = step
            }
            var spacingOk = maxDy <= Math.max(minDy * 2.2, minDy + medH * 1.4)

            if (spacingOk) {
              var trackHits = []
              for (var z = 0; z < sliceLen; z++) trackHits.push(0)
              var datumCount = 0
              var col1Count = 0
              var col1Numeric = 0
              var totalWords = 0
              var totalCells = 0

              for (var rr = 0; rr < run.length; rr++) {
                var rc = run[rr].cells
                for (var cc = 0; cc < rc.length; cc++) {
                  var off = rc[cc].trackOffset
                  var cellObj = rc[cc].cell
                  trackHits[off]++
                  totalCells++
                  totalWords += cellObj.wordCount
                  if (cellObj.isDatum) datumCount++
                  if (off === 1) {
                    col1Count++
                    if (cellObj.isNumeric) col1Numeric++
                  }
                }
              }

              var activeTracks = 0
              for (var th = 0; th < trackHits.length; th++) {
                if (trackHits[th] >= minRowsNeeded) activeTracks++
              }
              var avgWordsPerCell = totalCells > 0 ? totalWords / totalCells : 99

              if (avgWordsPerCell <= 3.5 && activeTracks >= minCols) {
                if (sliceLen >= 3 && (datumCount >= 2 || run.length >= 4)) {
                  return true
                }
                if (sliceLen === 2 && hasSelection && col1Count >= 4 && col1Numeric >= Math.ceil(col1Count * 0.5)) {
                  return true
                }
              }
            }
          }
        }

        runStart += Math.max(1, run.length)
      }
    }
  }

  return false
}

// Analyzes active OCR words, decoded QR/barcodes, selection bounds, and window
// metadata locally (0 ms) and returns up to 2 prioritized smart quick actions.
function detectScreenContext(opts) {
  var o = opts || ({})
  var words = Array.isArray(o.words) ? o.words : []
  var codes = Array.isArray(o.codes) ? o.codes : []
  var rects = Array.isArray(o.selectionRects) && o.selectionRects.length > 0
    ? o.selectionRects
    : (o.selectionRect ? [o.selectionRect] : [])
  var selectedText = String(o.selectedText || "").trim()

  var activeWords = words
  var activeCodes = codes

  if (rects.length > 0) {
    activeWords = []
    for (var i = 0; i < words.length; i++) {
      for (var r = 0; r < rects.length; r++) {
        if (_rectContainsCenter(rects[r], words[i], 4)) {
          activeWords.push(words[i])
          break
        }
      }
    }
    activeCodes = []
    for (var j = 0; j < codes.length; j++) {
      for (var cr = 0; cr < rects.length; cr++) {
        if (_rectOverlaps(rects[cr], codes[j])) {
          activeCodes.push(codes[j])
          break
        }
      }
    }
  }

  var activeText = selectedText
  if (!activeText && activeWords.length > 0) {
    var parts = []
    for (var w = 0; w < activeWords.length; w++) parts.push(activeWords[w].text)
    activeText = parts.join(" ")
  }

  var actions = []

  // 1. Highest-precision signal: QR code / barcode detected.
  if (activeCodes.length > 0) {
    var primaryCode = activeCodes[0]
    if (primaryCode.isUrl && isSafeHttpUrl(primaryCode.data)) {
      actions.push({
        kind: "qr_open",
        icon: "󰐲",
        labelKey: "chip.openQrUrl",
        payload: primaryCode.data
      })
      actions.push({
        kind: "qr_copy",
        icon: "󰆏",
        labelKey: "chip.copyQr",
        payload: primaryCode.data
      })
      return actions
    }
    actions.push({
      kind: "qr_copy",
      icon: "󰐲",
      labelKey: "chip.copyQr",
      payload: primaryCode.data
    })
  }

  // 2. Stack traces, compiler errors, HTTP errors, crash diagnostics.
  if (detectErrorSignal(activeText, o.windowClass)) {
    actions.push({
      kind: "diagnose",
      icon: "󰃤",
      labelKey: "chip.diagnose",
      payload: ""
    })
  }

  // 3. Tabular data (aligned multi-column OCR word grid).
  if (actions.length < 2 && detectTableLayout(activeWords, { hasSelection: rects.length > 0 })) {
    actions.push({
      kind: "extract_table",
      icon: "󰓫",
      labelKey: "chip.extractTable",
      payload: ""
    })
  }

  return actions.slice(0, 2)
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
// same transcript into the focused field right after ScreenLens inserted it
// (or right after auto-submit cleared the input box).
function dedupeLateVoicePaste(currentText, expectedAfterInsert, transcript) {
  var current = String(currentText || "")
  var expected = String(expectedAfterInsert || "")
  var clean = String(transcript || "").trim()
  if (!current || !clean || current === expected) return current

  var normCurrent = _normWhitespace(current)
  var normExpected = _normWhitespace(expected)
  var normClean = _normWhitespace(clean)
  if (!normExpected) {
    return normCurrent === normClean ? "" : current
  }
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

// Safely parses a JSON summon payload passed to ScreenLens.open(payloadJson).
function parseLaunchPayload(payloadJson) {
  var out = { voice: false, autoSubmit: null, continueFile: "", restoreFile: "" }
  if (!payloadJson) return out
  var obj = null
  if (typeof payloadJson === "object") {
    obj = payloadJson
  } else {
    try { obj = JSON.parse(String(payloadJson)) } catch (e) { obj = null }
  }
  if (!obj || typeof obj !== "object") return out
  if (obj.voice === true || obj.voiceAutoSubmit === true) {
    out.voice = true
  }
  if (typeof obj.voiceAutoSubmit === "boolean") {
    out.autoSubmit = obj.voiceAutoSubmit
  } else if (typeof obj.autoSubmit === "boolean") {
    out.autoSubmit = obj.autoSubmit
  }
  var ipcPathRe = /^\/tmp\/omarchy-screenlens-ipc-[0-9]+-[0-9]+-[A-Za-z0-9]{8,16}\.json$/
  if (typeof obj.continueFile === "string" && ipcPathRe.test(obj.continueFile.trim())) {
    out.continueFile = obj.continueFile.trim()
  }
  if (typeof obj.restoreFile === "string" && ipcPathRe.test(obj.restoreFile.trim())) {
    out.restoreFile = obj.restoreFile.trim()
  }
  return out
}

// Clamps a floating mini-card position cleanly inside screen bounds with margin.
function clampFloatingPosition(x, y, cardW, cardH, screenW, screenH, margin) {
  var m = typeof margin === "number" ? Math.max(0, margin) : 16
  var maxX = Math.max(m, Number(screenW || 0) - Number(cardW || 0) - m)
  var maxY = Math.max(m, Number(screenH || 0) - Number(cardH || 0) - m)
  return {
    x: Math.round(clamp(Number(x || 0), m, maxX)),
    y: Math.round(clamp(Number(y || 0), m, maxY))
  }
}

// Built-in default quick-action chips for Alt+1..4 when user has not customized them.
var DEFAULT_QUICK_CHIPS = [
  {
    id: "explain",
    label: "Explain",
    icon: "󰋗",
    action: "prompt",
    task: "auto",
    prompt: "Explain what is shown here clearly and concisely."
  },
  {
    id: "summarize",
    label: "Summarize",
    icon: "󰦨",
    action: "prompt",
    task: "auto",
    prompt: "Summarize the key points shown here in concise bullets."
  },
  {
    id: "translate",
    label: "Translate",
    icon: "󰗊",
    action: "prompt",
    task: "translate",
    prompt: "Translate any visible text here into {{language}}. If it is already in {{language}}, briefly clarify any jargon or idioms."
  },
  {
    id: "extract",
    label: "Extract Text",
    icon: "󰗧",
    action: "extract_text",
    task: "text",
    prompt: ""
  }
]

// Resolves user-configured quickChips into 4 safe, ready-to-render Alt+1..4 chip objects.
function resolveQuickChips(userConfig, fallbackLabels) {
  var fb = fallbackLabels || ({})
  var configured = (userConfig && Array.isArray(userConfig.quickChips)) ? userConfig.quickChips : []
  var out = []
  for (var i = 0; i < 4; i++) {
    var def = DEFAULT_QUICK_CHIPS[i]
    var defLabel = fb[def.id] || def.label
    var raw = (i < configured.length && configured[i] && typeof configured[i] === "object") ? configured[i] : null
    if (!raw) {
      out.push({
        id: def.id,
        label: defLabel,
        icon: def.icon,
        action: def.action,
        task: def.task,
        prompt: def.prompt,
        key: "Alt+" + (i + 1)
      })
      continue
    }
    var action = (raw.action === "extract_text") ? "extract_text" : "prompt"
    var task = String(raw.task || "auto")
    if (task !== "auto" && task !== "general" && task !== "vision" && task !== "text" && task !== "translate") {
      task = "auto"
    }
    var label = String(raw.label || "").replace(/\s+/g, " ").trim().slice(0, 28) || defLabel
    var icon = String(raw.icon || "").trim().slice(0, 4) || def.icon
    var prompt = String(raw.prompt || "").trim().slice(0, 1200)
    if (action === "prompt" && !prompt) {
      prompt = def.prompt || "Explain what is shown here clearly and concisely."
    }
    out.push({
      id: String(raw.id || ("chip-" + (i + 1))),
      label: label,
      icon: icon,
      action: action,
      task: action === "extract_text" ? "text" : task,
      prompt: action === "extract_text" ? "" : prompt,
      key: "Alt+" + (i + 1)
    })
  }
  return out
}

// Expands template placeholders (currently {{language}}) inside a quick-chip prompt.
function renderChipPrompt(template, vars) {
  var tpl = String(template || "").trim()
  if (!tpl) return ""
  var v = vars || ({})
  var lang = String(v.language || "English").trim() || "English"
  return tpl.replace(/\{\{\s*language\s*\}\}/gi, lang)
}

function _formatUtilityNumber(num, maxDecimals) {
  if (typeof num !== "number" || !isFinite(num)) return ""
  var dec = typeof maxDecimals === "number" ? maxDecimals : 2
  var rounded = Number(num.toFixed(dec))
  if (Object.is(rounded, -0)) rounded = 0
  var str = String(rounded)
  var parts = str.split(".")
  if (Math.abs(rounded) >= 10000) {
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  }
  return parts.length > 1 ? (parts[0] + "." + parts[1]) : parts[0]
}

// Strict safe recursive-descent arithmetic evaluator (never uses eval/Function).
function _safeEvalArithmetic(expr) {
  var src = String(expr || "").trim()
  if (!src || src.length > 64) return null
  // Normalize unicode operators and strip thousand-separator commas inside numbers.
  var norm = src
    .replace(/[×✕]/g, "*")
    .replace(/[÷]/g, "/")
    .replace(/[−–—]/g, "-")
    .replace(/(\d),(?=\d{3}\b)/g, "$1")

  // Reject dates (2026-11-28, 11/28/2026, 11/28), phone numbers, and bare numbers.
  if (/^\d{4}-\d{1,2}-\d{1,2}$/.test(norm)) return null
  if (/^\d{1,2}\/\d{1,2}(?:\/\d{2,4})?$/.test(norm)) return null
  if (/^\d{3}-\d{3,4}(?:-\d{4})?$/.test(norm)) return null
  if (/^[\d.\s]+$/.test(norm)) return null
  if (!/^[0-9.\s+\-*/^()]+$/.test(norm)) return null

  // Tokenize numbers, operators, and parens.
  var tokens = []
  var i = 0
  var hasOp = false
  while (i < norm.length) {
    var ch = norm[i]
    if (ch === " " || ch === "\t") { i++; continue }
    if ((ch >= "0" && ch <= "9") || ch === ".") {
      var start = i
      var dots = 0
      while (i < norm.length && ((norm[i] >= "0" && norm[i] <= "9") || norm[i] === ".")) {
        if (norm[i] === ".") dots++
        i++
      }
      if (dots > 1) return null
      var rawNum = norm.slice(start, i)
      if (rawNum === ".") return null
      var val = parseFloat(rawNum)
      if (!isFinite(val)) return null
      tokens.push({ t: "num", v: val })
      continue
    }
    if (ch === "+" || ch === "-" || ch === "*" || ch === "/" || ch === "^") {
      hasOp = true
      tokens.push({ t: "op", v: ch })
      i++
      continue
    }
    if (ch === "(" || ch === ")") {
      tokens.push({ t: ch, v: ch })
      i++
      continue
    }
    return null
  }
  if (!hasOp || tokens.length < 3) return null

  // Reject compact integer-hyphen-integer sports scores or IDs like "26-13" when
  // there are no spaces and no other operators; "26 - 13" with spaces evaluates.
  if (/^\d{1,3}-\d{1,3}$/.test(norm)) return null

  var pos = 0
  var depth = 0
  function peek() { return pos < tokens.length ? tokens[pos] : null }
  function consume() { return tokens[pos++] }

  function parseExpr() {
    var left = parseTerm()
    if (left === null) return null
    while (peek() && peek().t === "op" && (peek().v === "+" || peek().v === "-")) {
      var op = consume().v
      var right = parseTerm()
      if (right === null) return null
      left = op === "+" ? (left + right) : (left - right)
      if (!isFinite(left)) return null
    }
    return left
  }

  function parseTerm() {
    var left = parsePower()
    if (left === null) return null
    while (peek() && peek().t === "op" && (peek().v === "*" || peek().v === "/")) {
      var op = consume().v
      var right = parsePower()
      if (right === null) return null
      if (op === "/") {
        if (Math.abs(right) < 1e-12) return null
        left = left / right
      } else {
        left = left * right
      }
      if (!isFinite(left)) return null
    }
    return left
  }

  function parsePower() {
    var base = parseUnary()
    if (base === null) return null
    if (peek() && peek().t === "op" && peek().v === "^") {
      consume()
      var exp = parsePower()
      if (exp === null || Math.abs(exp) > 100) return null
      var res = Math.pow(base, exp)
      if (!isFinite(res)) return null
      return res
    }
    return base
  }

  function parseUnary() {
    if (peek() && peek().t === "op" && (peek().v === "+" || peek().v === "-")) {
      var op = consume().v
      var inner = parseUnary()
      if (inner === null) return null
      return op === "-" ? -inner : inner
    }
    return parsePrimary()
  }

  function parsePrimary() {
    var tok = peek()
    if (!tok) return null
    if (tok.t === "num") {
      consume()
      return tok.v
    }
    if (tok.t === "(") {
      if (depth >= 12) return null
      depth++
      consume()
      var inner = parseExpr()
      if (inner === null || !peek() || peek().t !== ")") return null
      consume()
      depth--
      return inner
    }
    return null
  }

  var result = parseExpr()
  if (result === null || pos !== tokens.length || !isFinite(result)) return null
  return result
}

// Strips stray OCR wrapper punctuation (bullets, backticks, trailing commas/periods)
// without damaging negative signs, math parentheses, or compound inch marks (5'11").
function _cleanUtilityInput(text) {
  var s = String(text || "").replace(/\s+/g, " ").trim()
  if (!s) return ""
  // Strip leading bullets, dots, quotes, backticks, chevrons, or bullet misreads ("+ " before non-digit / paren)
  s = s.replace(/^[•·▪▫◦‣⁃«»`'"*,;:\s]+/, "")
  // Strip trailing bullets, backticks, commas, semicolons, colons, periods (preserve trailing " after digit for 5'11")
  s = s.replace(/[•·▪▫◦‣⁃«»`',;:\.\s]+$/, "")
  if (s.length >= 2 && s[0] === '"' && s[s.length - 1] === '"') {
    s = s.slice(1, -1).trim()
  }
  // If OCR misread a leading bullet dot as "+ " before a unit/temp/time (e.g. "+ 145 km"), strip it.
  if (/^\+\s+\S/.test(s) && !/^\+\s*\d[\d.,]*\s*[+\-*/×÷^]/.test(s)) {
    s = s.replace(/^\+\s+/, "")
  }
  return s.trim()
}

// Evaluates short selected text locally (0 ms, zero API calls, zero eval) for
// temperature, common unit conversions, timezones, percentages, and arithmetic.
function evaluateLocalUtility(text, opts) {
  var clean = _cleanUtilityInput(text)
  if (clean.length < 2 || clean.length > 64) return null

  var o = opts || ({})

  // 1. Temperature (°F <-> °C, K -> °C)
  var tempMatch = clean.match(/^([+-]?\d+(?:\.\d+)?)\s*(?:(°|º|deg(?:rees?)?)\s*)?(fahrenheit|celsius|kelvin|[CFK])$/i)
  if (tempMatch) {
    var tVal = parseFloat(tempMatch[1])
    var hasDeg = !!tempMatch[2]
    var unitRaw = tempMatch[3].toLowerCase()
    var hasSpace = /\s/.test(clean)
    var isFullWord = unitRaw.length > 1
    // Require °/deg, full unit name, or whitespace + realistic range so "2C" or "4F" codes never trigger.
    if (isFinite(tVal) && (hasDeg || isFullWord || (hasSpace && tVal >= -150 && tVal <= 2000))) {
      var u = unitRaw[0]
      if (u === "f") {
        var cVal = (tVal - 32) * 5 / 9
        var cStr = _formatUtilityNumber(cVal, 1) + " °C"
        return { kind: "temp", icon: "󰔏", label: cStr, copyValue: cStr, detail: clean + " = " + cStr }
      }
      if (u === "c") {
        var fVal = tVal * 9 / 5 + 32
        var fStr = _formatUtilityNumber(fVal, 1) + " °F"
        return { kind: "temp", icon: "󰔏", label: fStr, copyValue: fStr, detail: clean + " = " + fStr }
      }
      if (u === "k" && tVal >= 0 && (isFullWord || hasSpace)) {
        var kcVal = tVal - 273.15
        var kcStr = _formatUtilityNumber(kcVal, 1) + " °C"
        return { kind: "temp", icon: "󰔏", label: kcStr, copyValue: kcStr, detail: clean + " = " + kcStr }
      }
    }
  }

  // 2. Timezone conversion to local time (e.g. "2:30 PM PST", "14:00 UTC", "9am EST")
  var tzMatch = clean.match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(UTC|GMT|EST|EDT|CST|CDT|MST|MDT|PST|PDT|ET|CT|MT|PT|BST|CET|CEST|IST|JST|AEST|AEDT)$/i)
  if (tzMatch) {
    var hr = parseInt(tzMatch[1], 10)
    var min = tzMatch[2] !== undefined ? parseInt(tzMatch[2], 10) : 0
    var ampm = tzMatch[3] ? tzMatch[3].toLowerCase() : ""
    var tzCode = tzMatch[4].toUpperCase()
    var validTime = (tzMatch[2] !== undefined || ampm !== "") && min >= 0 && min <= 59
    if (validTime) {
      if (ampm) {
        if (hr < 1 || hr > 12) validTime = false
        else {
          if (ampm === "pm" && hr !== 12) hr += 12
          if (ampm === "am" && hr === 12) hr = 0
        }
      } else if (hr < 0 || hr > 23) {
        validTime = false
      }
    }
    if (validTime) {
      var refDate = o.nowDate instanceof Date ? o.nowDate : new Date()
      // Standard UTC offsets in minutes (positive east of UTC, negative west).
      var janOff = new Date(refDate.getFullYear(), 0, 1).getTimezoneOffset()
      var julOff = new Date(refDate.getFullYear(), 6, 1).getTimezoneOffset()
      var isDstLocal = refDate.getTimezoneOffset() < Math.max(janOff, julOff)
      var tzOffsets = {
        UTC: 0, GMT: 0,
        EST: -300, EDT: -240, ET: isDstLocal ? -240 : -300,
        CST: -360, CDT: -300, CT: isDstLocal ? -300 : -360,
        MST: -420, MDT: -360, MT: isDstLocal ? -360 : -420,
        PST: -480, PDT: -420, PT: isDstLocal ? -420 : -480,
        BST: 60, CET: 60, CEST: 120, IST: 330, JST: 540, AEST: 600, AEDT: 660
      }
      if (Object.prototype.hasOwnProperty.call(tzOffsets, tzCode)) {
        var srcOffMin = tzOffsets[tzCode]
        // JS getTimezoneOffset() is minutes WEST of UTC, so local east-offset is -getTimezoneOffset().
        var localOffMin = typeof o.localOffsetMin === "number" ? o.localOffsetMin : (-refDate.getTimezoneOffset())
        var targetOffMin = (srcOffMin === localOffMin) ? 0 : localOffMin
        var targetSuffix = (srcOffMin === localOffMin) ? "UTC" : "local"
        var totalMin = hr * 60 + min - srcOffMin + targetOffMin
        var dayDelta = 0
        while (totalMin < 0) { totalMin += 1440; dayDelta -= 1 }
        while (totalMin >= 1440) { totalMin -= 1440; dayDelta += 1 }
        var outHr24 = Math.floor(totalMin / 60)
        var outMin = totalMin % 60
        var minPad = outMin < 10 ? ("0" + outMin) : String(outMin)
        var formatted = ""
        if (targetSuffix === "UTC") {
          var hrPad = outHr24 < 10 ? ("0" + outHr24) : String(outHr24)
          formatted = hrPad + ":" + minPad + " UTC"
        } else {
          var outAmPm = outHr24 >= 12 ? "PM" : "AM"
          var outHr12 = outHr24 % 12
          if (outHr12 === 0) outHr12 = 12
          formatted = outHr12 + ":" + minPad + " " + outAmPm
        }
        var dayTag = dayDelta > 0 ? " (+1d)" : (dayDelta < 0 ? " (-1d)" : "")
        var label = targetSuffix === "UTC" ? (formatted + dayTag) : (formatted + " local" + dayTag)
        return { kind: "time", icon: "󰥔", label: label, copyValue: formatted, detail: clean + " = " + label }
      }
    }
  }

  // 3. Compound feet & inches height (e.g. 5'11", 5 ft 11 in)
  var heightMatch = clean.match(/^(\d{1,2})\s*(?:'|ft|feet)\s*(\d{1,2}(?:\.\d+)?)\s*(?:"|in|inches)?$/i)
  if (heightMatch) {
    var ft = parseInt(heightMatch[1], 10)
    var inch = parseFloat(heightMatch[2])
    if (ft >= 0 && ft <= 12 && inch >= 0 && inch < 12) {
      var cmH = (ft * 12 + inch) * 2.54
      var cmStr = _formatUtilityNumber(cmH, 1) + " cm"
      return { kind: "unit", icon: "󰓡", label: cmStr, copyValue: cmStr, detail: clean + " = " + cmStr }
    }
  }

  // 4. Standard metric <-> imperial unit conversions
  var unitMatch = clean.match(/^([+-]?\d[\d,]*(?:\.\d+)?)(\s*)(km|kilometers?|kilometres?|mi|miles?|meters?|metres?|m|ft|feet|foot|inches|inch|in|cm|centimeters?|centimetres?|mm|millimeters?|millimetres?|yd|yards?|kg|kilograms?|grams?|g|lbs?|pounds?|oz|ounces?|liters?|litres?|ml|milliliters?|millilitres?|gal|gallons?|mph|kph|km\/h)$/i)
  if (unitMatch) {
    var uNum = parseFloat(unitMatch[1].replace(/,/g, ""))
    var uSpace = unitMatch[2]
    var uKey = unitMatch[3].toLowerCase()
    // Avoid false positives on chat timestamps like "5m" or short codes like "2g" / "4in" without clear context.
    var ambiguousBare = (uKey === "m" || uKey === "g" || uKey === "in") && !uSpace
    if (isFinite(uNum) && !ambiguousBare) {
      var convTable = {
        km: [0.621371, "mi", 2], kilometer: [0.621371, "mi", 2], kilometers: [0.621371, "mi", 2], kilometre: [0.621371, "mi", 2], kilometres: [0.621371, "mi", 2],
        mi: [1.609344, "km", 2], mile: [1.609344, "km", 2], miles: [1.609344, "km", 2],
        m: [3.28084, "ft", 2], meter: [3.28084, "ft", 2], meters: [3.28084, "ft", 2], metre: [3.28084, "ft", 2], metres: [3.28084, "ft", 2],
        ft: [0.3048, "m", 2], foot: [0.3048, "m", 2], feet: [0.3048, "m", 2],
        cm: [0.393701, "in", 2], centimeter: [0.393701, "in", 2], centimeters: [0.393701, "in", 2], centimetre: [0.393701, "in", 2], centimetres: [0.393701, "in", 2],
        mm: [0.0393701, "in", 2], millimeter: [0.0393701, "in", 2], millimeters: [0.0393701, "in", 2], millimetre: [0.0393701, "in", 2], millimetres: [0.0393701, "in", 2],
        in: [2.54, "cm", 2], inch: [2.54, "cm", 2], inches: [2.54, "cm", 2],
        yd: [0.9144, "m", 2], yard: [0.9144, "m", 2], yards: [0.9144, "m", 2],
        kg: [2.204623, "lb", 2], kilogram: [2.204623, "lb", 2], kilograms: [2.204623, "lb", 2],
        lb: [0.453592, "kg", 2], lbs: [0.453592, "kg", 2], pound: [0.453592, "kg", 2], pounds: [0.453592, "kg", 2],
        g: [0.035274, "oz", 2], gram: [0.035274, "oz", 2], grams: [0.035274, "oz", 2],
        oz: [28.34952, "g", 1], ounce: [28.34952, "g", 1], ounces: [28.34952, "g", 1],
        liter: [0.264172, "gal", 2], liters: [0.264172, "gal", 2], litre: [0.264172, "gal", 2], litres: [0.264172, "gal", 2],
        ml: [0.033814, "fl oz", 2], milliliter: [0.033814, "fl oz", 2], milliliters: [0.033814, "fl oz", 2], millilitre: [0.033814, "fl oz", 2], millilitres: [0.033814, "fl oz", 2],
        gal: [3.785412, "L", 2], gallon: [3.785412, "L", 2], gallons: [3.785412, "L", 2],
        mph: [1.609344, "km/h", 1],
        kph: [0.621371, "mph", 1], "km/h": [0.621371, "mph", 1]
      }
      var spec = convTable[uKey]
      if (spec) {
        var outStr = _formatUtilityNumber(uNum * spec[0], spec[2]) + " " + spec[1]
        return { kind: "unit", icon: "󰓡", label: outStr, copyValue: outStr, detail: clean + " = " + outStr }
      }
    }
  }

  // 5. Percentages ("18% of 240", "18% of $240", "$240 - 15%", "240 + 18%")
  var pctOf = clean.match(/^([+-]?\d+(?:\.\d+)?)\s*%\s+of\s+([\$€£])?\s*(\d[\d,]*(?:\.\d+)?)$/i)
  if (pctOf) {
    var pct = parseFloat(pctOf[1])
    var sym = pctOf[2] || ""
    var base = parseFloat(pctOf[3].replace(/,/g, ""))
    if (isFinite(pct) && isFinite(base)) {
      var pRes = (pct / 100) * base
      var pFmt = sym ? (sym + pRes.toFixed(2)) : _formatUtilityNumber(pRes, 4)
      return { kind: "math", icon: "󰃬", label: "= " + pFmt, copyValue: pFmt, detail: clean + " = " + pFmt }
    }
  }
  var pctDelta = clean.match(/^([\$€£])?\s*(\d[\d,]*(?:\.\d+)?)\s*([+\-])\s*(\d+(?:\.\d+)?)\s*%$/)
  if (pctDelta) {
    var dSym = pctDelta[1] || ""
    var dBase = parseFloat(pctDelta[2].replace(/,/g, ""))
    var dSign = pctDelta[3] === "-" ? -1 : 1
    var dPct = parseFloat(pctDelta[4])
    if (isFinite(dBase) && isFinite(dPct)) {
      var dRes = dBase * (1 + dSign * (dPct / 100))
      var dFmt = dSym ? (dSym + dRes.toFixed(2)) : _formatUtilityNumber(dRes, 4)
      return { kind: "math", icon: "󰃬", label: "= " + dFmt, copyValue: dFmt, detail: clean + " = " + dFmt }
    }
  }

  // 6. Safe arithmetic expressions ("(1450 - 320) / 4", "12 * 8", "1,450 - 320")
  var mathVal = _safeEvalArithmetic(clean)
  if (mathVal !== null) {
    var mFmt = _formatUtilityNumber(mathVal, 4)
    return { kind: "math", icon: "󰃬", label: "= " + mFmt, copyValue: mFmt, detail: clean + " = " + mFmt }
  }

  return null
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
