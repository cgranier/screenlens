import assert from "node:assert/strict"
import fs from "node:fs"
import path from "node:path"
import vm from "node:vm"

const rootDir = path.resolve(import.meta.dirname, "..")
const rawSource = fs.readFileSync(path.join(rootDir, "ScreenLensLogic.js"), "utf8")
const cleanedSource = rawSource.replace(/^\.pragma\s+library\s*\n/, "")

const sandbox = {}
vm.createContext(sandbox)
vm.runInContext(cleanedSource, sandbox)
const plain = (v) => JSON.parse(JSON.stringify(v))

// 1. Markup neutralization regression tests (Omarchy Plugin UI Safety)
assert.equal(
  sandbox.neutralizeMarkup('<img src="https://example.invalid/tracker"> & <b>hi</b>'),
  "&lt;img src=&quot;https://example.invalid/tracker&quot;&gt; &amp; &lt;b&gt;hi&lt;/b&gt;"
)
assert.equal(sandbox.neutralizeMarkup(null), "")
assert.equal(sandbox.neutralizeMarkup("plain text"), "plain text")

// 2. Lasso bounding box calculation, padding, clamping, and click rejection
assert.equal(
  sandbox.computeSelectionRect([{ x: 100, y: 100 }, { x: 105, y: 103 }], 1920, 1080, 8),
  null,
  "tiny accidental click should not create a selection"
)

const lassoRect = sandbox.computeSelectionRect(
  [{ x: 4, y: 10 }, { x: 200, y: 15 }, { x: 180, y: 120 }, { x: 10, y: 90 }],
  1920,
  1080,
  8
)
assert.deepEqual(plain(lassoRect), { x: 0, y: 2, w: 208, h: 126 })

// 2a. Box marquee rectangle calculation (normal, reversed, clamped, click rejection)
assert.equal(sandbox.computeBoxRect(100, 100, 104, 103, 1920, 1080, 8), null)
assert.deepEqual(plain(sandbox.computeBoxRect(100, 120, 340, 260, 1920, 1080, 8)), { x: 100, y: 120, w: 240, h: 140 })
assert.deepEqual(plain(sandbox.computeBoxRect(340, 260, 100, 120, 1920, 1080, 8)), { x: 100, y: 120, w: 240, h: 140 })
assert.deepEqual(plain(sandbox.computeBoxRect(-20, 10, 2000, 1200, 1920, 1080, 8)), { x: 0, y: 10, w: 1920, h: 1070 })

// 2b. Crop handle hit-testing, move/resize clamping, and multi-region stacking
const box = { x: 100, y: 100, w: 200, h: 150 }
assert.equal(sandbox.hitTestCropHandle(box, 100, 100, 12), "nw")
assert.equal(sandbox.hitTestCropHandle(box, 300, 100, 12), "ne")
assert.equal(sandbox.hitTestCropHandle(box, 100, 250, 12), "sw")
assert.equal(sandbox.hitTestCropHandle(box, 300, 250, 12), "se")
assert.equal(sandbox.hitTestCropHandle(box, 200, 100, 12), "n")
assert.equal(sandbox.hitTestCropHandle(box, 200, 250, 12), "s")
assert.equal(sandbox.hitTestCropHandle(box, 100, 175, 12), "w")
assert.equal(sandbox.hitTestCropHandle(box, 300, 175, 12), "e")
assert.equal(sandbox.hitTestCropHandle(box, 200, 175, 12), "move")
assert.equal(sandbox.hitTestCropHandle(box, 40, 40, 12), "")

// Move clamped inside overlay bounds (never shrinks box)
assert.deepEqual(plain(sandbox.applyCropDrag(box, "move", 50, -40, 1920, 1080, 16)), { x: 150, y: 60, w: 200, h: 150 })
assert.deepEqual(plain(sandbox.applyCropDrag(box, "move", -500, 2000, 1920, 1080, 16)), { x: 0, y: 930, w: 200, h: 150 })

// Resize from nw/se clamped to minSize=16 and overlay edges
assert.deepEqual(plain(sandbox.applyCropDrag(box, "se", 40, -30, 1920, 1080, 16)), { x: 100, y: 100, w: 240, h: 120 })
assert.deepEqual(plain(sandbox.applyCropDrag(box, "nw", 500, 500, 1920, 1080, 16)), { x: 284, y: 234, w: 16, h: 16 })
assert.deepEqual(plain(sandbox.applyCropDrag(box, "e", 5000, 0, 1920, 1080, 16)), { x: 100, y: 100, w: 1820, h: 150 })

// Multi-region hit-testing prioritizes topmost (latest) region on overlap
const stacked = [
  { x: 100, y: 100, w: 200, h: 200 },
  { x: 150, y: 150, w: 200, h: 200 }
]
assert.deepEqual(plain(sandbox.hitTestRegions(stacked, 200, 200, 12)), { index: 1, handle: "move" })
assert.deepEqual(plain(sandbox.hitTestRegions(stacked, 110, 110, 12)), { index: 0, handle: "nw" })
assert.deepEqual(plain(sandbox.hitTestRegions(stacked, 10, 10, 12)), { index: -1, handle: "" })

// 3. Logical-to-image HiDPI scaling (e.g. 1.5x monitor)
const imgCrop = sandbox.logicalToImageRect({ x: 100, y: 200, w: 400, h: 300 }, 1920, 1080, 2880, 1620)
assert.deepEqual(plain(imgCrop), { x: 150, y: 300, w: 600, h: 450 })

// 4. OCR word coordinate mapping, hit testing, and multi-line reading-order selection
const rawWords = [
  { text: "Hello", x: 100, y: 100, w: 80, h: 30, block: 1, par: 1, line: 1 },
  { text: "Omarchy", x: 200, y: 100, w: 120, h: 30, block: 1, par: 1, line: 1 },
  { text: "world!", x: 100, y: 150, w: 90, h: 30, block: 1, par: 1, line: 2 }
]
const mapped = sandbox.mapWordsToOverlay(rawWords, 2000, 1000, 1000, 500)
assert.equal(mapped.length, 3)
assert.equal(mapped[0].x, 50)
assert.equal(mapped[0].y, 50)
assert.equal(mapped[0].w, 40)

assert.equal(sandbox.hitTestWord(mapped, 60, 55, 20), 0)
assert.equal(sandbox.hitTestWord(mapped, 120, 55, 20), 1)
assert.equal(sandbox.hitTestWord(mapped, 900, 450, 20), -1)

const forwardSel = sandbox.selectWordsBetween(mapped, 0, 2, null)
assert.equal(forwardSel.text, "Hello Omarchy\nworld!")
assert.deepEqual(plain(forwardSel.indices), [0, 1, 2])
assert.equal(forwardSel.bounds.x, 50)
assert.equal(forwardSel.bounds.y, 50)

const reverseSel = sandbox.selectWordsBetween(mapped, 2, 1, null)
assert.equal(reverseSel.text, "Omarchy\nworld!")

const rectExtract = sandbox.extractWordsInRect(mapped, { x: 45, y: 45, w: 120, h: 20 })
assert.equal(rectExtract.text, "Hello Omarchy")
assert.deepEqual(plain(rectExtract.indices), [0, 1])

// 5. Agent handoff prompt formatting
const handoff = sandbox.buildAgentHandoffPrompt({
  windowClass: "chromium",
  windowTitle: "Docs",
  imagePath: "/tmp/shot.png",
  crop: { x: 10, y: 20, w: 300, h: 200 },
  selectedText: "error: missing semicolon",
  messages: [
    { role: "user", text: "What does this error mean?" },
    { role: "assistant", text: "You are missing a semicolon on line 4." }
  ],
  draftPrompt: "Fix it in main.cpp"
})
assert.match(handoff, /chromium — Docs/)
assert.match(handoff, /\/tmp\/shot\.png/)
assert.match(handoff, /error: missing semicolon/)
assert.match(handoff, /Fix it in main\.cpp/)

// 6. Theme mode palette resolution preserves live Omarchy accent
const sysPal = { background: "#111111", text: "#eeeeee", border: "#444444", scrim: "#70111111", accent: "#ff9900", urgent: "#ff2222" }
assert.equal(sandbox.resolveThemePalette("system", sysPal).background, "#111111")
assert.equal(sandbox.resolveThemePalette("dark", sysPal).accent, "#ff9900")
assert.equal(sandbox.resolveThemePalette("dark", sysPal).background, "#181a22")
assert.equal(sandbox.resolveThemePalette("light", sysPal).accent, "#ff9900")
assert.equal(sandbox.resolveThemePalette("light", sysPal).background, "#f5f6fa")
assert.equal(sandbox.resolveThemePalette("invalid", sysPal).background, "#111111")

// 7. Superwhisper voice transcript deduplication (auto-paste on/off + late paste)
assert.equal(
  sandbox.mergeVoiceTranscript("", "", "What is this error?"),
  "What is this error?"
)
assert.equal(
  sandbox.mergeVoiceTranscript("Explain:", "Explain:", "What is this error?"),
  "Explain: What is this error?"
)
assert.equal(
  sandbox.mergeVoiceTranscript("", "What is this error?", "What is this error?"),
  "What is this error?",
  "already auto-pasted transcript must not be appended a second time"
)
assert.equal(
  sandbox.mergeVoiceTranscript("Explain: ", "Explain: What is this error?", "What is this error?"),
  "Explain: What is this error?"
)
assert.equal(
  sandbox.dedupeLateVoicePaste("What is this error? What is this error?", "What is this error?", "What is this error?"),
  "What is this error?",
  "late auto-paste with space should collapse to one copy"
)
assert.equal(
  sandbox.dedupeLateVoicePaste("What is this error?What is this error?", "What is this error?", "What is this error?"),
  "What is this error?",
  "late auto-paste without space should collapse to one copy"
)
assert.equal(
  sandbox.dedupeLateVoicePaste("What is this error? please", "What is this error?", "What is this error?"),
  "What is this error? please",
  "normal user typing after dictation must not be stripped"
)
assert.equal(
  sandbox.dedupeLateVoicePaste("What is this error?", "", "What is this error?"),
  "",
  "late auto-paste after voice auto-submit clears input must be stripped"
)
assert.deepEqual(plain(sandbox.parseLaunchPayload("")), { voice: false, autoSubmit: null })
assert.deepEqual(plain(sandbox.parseLaunchPayload('{"voice":true}')), { voice: true, autoSubmit: null })
assert.deepEqual(plain(sandbox.parseLaunchPayload('{"voiceAutoSubmit":true}')), { voice: true, autoSubmit: true })
assert.deepEqual(plain(sandbox.parseLaunchPayload('{"voice":true,"autoSubmit":false}')), { voice: true, autoSubmit: false })
assert.deepEqual(plain(sandbox.parseLaunchPayload("not-json")), { voice: false, autoSubmit: null })

// 8. Contrast ink helper and PlainText-safe answer block parser
assert.equal(sandbox.inkOn("#f5f6fa"), "#101315")
assert.equal(sandbox.inkOn("#181a22"), "#f5f6fa")

const parsed = plain(sandbox.parseAnswerBlocks(
  "## Summary\n\n**Key picks:**\nHere is the `fix`:\n- **First** item\n2. Second item\n\n```python\nprint('**keep**')\n```\n\nDone."
))
assert.equal(parsed.length, 7)
assert.equal(parsed[0].kind, "heading")
assert.equal(parsed[0].text, "Summary")
assert.equal(parsed[1].kind, "subheading")
assert.equal(parsed[1].text, "Key picks:")
assert.equal(parsed[2].kind, "paragraph")
assert.equal(parsed[2].text, "Here is the fix:")
assert.equal(parsed[3].kind, "bullet")
assert.equal(parsed[3].lang, "•")
assert.equal(parsed[3].text, "First item")
assert.equal(parsed[4].kind, "bullet")
assert.equal(parsed[4].lang, "2.")
assert.equal(parsed[5].kind, "code")
assert.equal(parsed[5].lang, "python")
assert.equal(parsed[5].text, "print('**keep**')")
assert.equal(parsed[6].kind, "paragraph")
assert.equal(parsed[6].text, "Done.")

// Streaming unclosed fence should still render cleanly as a code block
const streamingParsed = plain(sandbox.parseAnswerBlocks("Intro\n```bash\necho 1"))
assert.equal(streamingParsed.length, 2)
assert.equal(streamingParsed[1].kind, "code")
assert.equal(streamingParsed[1].lang, "bash")
assert.equal(streamingParsed[1].text, "echo 1")

// 9. Context-aware quick actions: URL validation, error diagnostics, tables, QR codes
assert.equal(sandbox.isSafeHttpUrl("https://github.com/cgranier/screenlens"), true)
assert.equal(sandbox.isSafeHttpUrl("http://example.com/path?a=1"), true)
assert.equal(sandbox.isSafeHttpUrl("javascript:alert(1)"), false)
assert.equal(sandbox.isSafeHttpUrl("file:///etc/passwd"), false)
assert.equal(sandbox.isSafeHttpUrl("data:text/html,<b>hi</b>"), false)
assert.equal(sandbox.isSafeHttpUrl("https://example.com/bad space"), false)

// Error / stack trace detection
assert.equal(sandbox.detectErrorSignal("Traceback (most recent call last):\nTypeError: x is undefined", "ghostty"), true)
assert.equal(sandbox.detectErrorSignal("HTTP 502 Bad Gateway", "chromium"), true)
assert.equal(sandbox.detectErrorSignal("error: cannot find crate foo", "ghostty"), true)
assert.equal(sandbox.detectErrorSignal("Good morning, here is today's forecast.", "chromium"), false)

// Tabular layout detection from aligned multi-column OCR word boxes
const tableWords = [
  { text: "Player", x: 40, y: 40, w: 60, h: 16 },
  { text: "Team",   x: 200, y: 40, w: 45, h: 16 },
  { text: "Pts",    x: 340, y: 40, w: 30, h: 16 },
  { text: "Allen",  x: 40, y: 70, w: 50, h: 16 },
  { text: "BUF",    x: 202, y: 70, w: 35, h: 16 },
  { text: "28.4",   x: 342, y: 70, w: 35, h: 16 },
  { text: "Jackson",x: 40, y: 100, w: 70, h: 16 },
  { text: "BAL",    x: 199, y: 100, w: 35, h: 16 },
  { text: "26.1",   x: 339, y: 100, w: 35, h: 16 }
]
assert.equal(sandbox.detectTableLayout(tableWords), true)
assert.equal(sandbox.detectTableLayout(mapped), false)

// Context priority: QR URL in selection surfaces Open QR Link + Copy QR
const mappedCodes = plain(sandbox.mapCodesToOverlay(
  [{ type: "QR-Code", data: "https://github.com/cgranier/screenlens", isUrl: true, x: 200, y: 200, w: 200, h: 200 }],
  2000, 1000, 1000, 500
))
const qrActions = plain(sandbox.detectScreenContext({
  words: tableWords,
  codes: mappedCodes,
  selectionRects: [{ x: 90, y: 90, w: 120, h: 120 }],
  selectedText: "",
  windowClass: "chromium"
}))
assert.equal(qrActions.length, 2)
assert.equal(qrActions[0].kind, "qr_open")
assert.equal(qrActions[1].kind, "qr_copy")

// Unsafe QR scheme only offers Copy QR (never Open QR Link)
const unsafeQrActions = plain(sandbox.detectScreenContext({
  words: [],
  codes: [{ type: "QR-Code", data: "javascript:alert(1)", isUrl: false, x: 100, y: 100, w: 80, h: 80 }],
  selectionRects: [],
  selectedText: "",
  windowClass: "chromium"
}))
assert.equal(unsafeQrActions.length, 1)
assert.equal(unsafeQrActions[0].kind, "qr_copy")

// Table + error detection via detectScreenContext
const tableActions = plain(sandbox.detectScreenContext({
  words: tableWords,
  codes: [],
  selectionRects: [],
  selectedText: "",
  windowClass: "chromium"
}))
assert.equal(tableActions.some(a => a.kind === "extract_table"), true)

const errActions = plain(sandbox.detectScreenContext({
  words: [],
  codes: [],
  selectionRects: [],
  selectedText: "SyntaxError: unexpected token at app.js:42",
  windowClass: "ghostty"
}))
assert.equal(errActions[0].kind, "diagnose")

console.log("test_logic.mjs: ALL PASSED")
