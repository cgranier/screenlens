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

console.log("test_logic.mjs: ALL PASSED")
