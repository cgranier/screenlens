# ScreenLens (`carlos.screenlens`)

An Android "Circle to Search"-style on-screen AI overlay plugin for the Omarchy shell.

## Features

- **Instant Frozen-Screen Overlay:** Summon over any window or workspace via hotkey (`Super + Alt + A` by default) to freeze the active monitor without flicker.
- **Circle / Lasso & Region Crop:** Drag freely around anything on screen to crop and ask about that exact area.
- **On-Screen Text Selection (OCR):** Runs Tesseract word-box OCR in the background as soon as the overlay opens; press `Tab` (or click **Select Text**) to highlight any visible text on screen, copy it (`Ctrl+C`), or ask AI about it.
- **Quick-Action Chips:** One-click (`Alt+1..4`) **Explain**, **Summarize**, **Translate**, and **Extract Text**.
- **Superwhisper Voice Input:** Press `Ctrl+M` (or click the mic button) to dictate your question straight into the prompt bar.
- **Hybrid Vision Backend + Agent Handoff:**
  - Streams 1–2s answers from **Gemini**, **Anthropic**, **OpenAI**, or local **Ollama** when configured.
  - Automatically falls back to your Omarchy default CLI agent when no direct API key is configured.
  - Click **Continue in Agent** (`Ctrl+Shift+Enter`) at any time to hand the screenshot, crop, selected text, and conversation over to `omarchy agent prompt`.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Super + Alt + A` | Toggle ScreenLens overlay (configurable in `~/.config/hypr/bindings.lua`) |
| `Tab` | Switch between **Circle / Region** and **Select Text** modes |
| `Enter` | Send prompt / follow-up |
| `Ctrl + M` | Toggle Superwhisper voice dictation |
| `Alt + 1..4` | Explain / Summarize / Translate / Extract Text |
| `Ctrl + C` | Copy selected text, latest answer, or cropped region |
| `Ctrl + Shift + Enter` | Hand off context + chat to your Omarchy default agent |
| `Esc` | Stop voice / cancel streaming / clear selection / dismiss |

## Vision API Configuration (Optional — for 1–2s direct streaming)

ScreenLens auto-detects `GEMINI_API_KEY` (`GOOGLE_API_KEY`), `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or `OLLAMA_HOST`, or reads `~/.config/omarchy/screenlens.json`:

```json
{
  "provider": "gemini",
  "model": "gemini-2.5-flash",
  "apiKey": "your-key-here"
}
```

Supported `provider` values: `"auto"` (default), `"gemini"`, `"anthropic"`, `"openai"`, `"ollama"`, `"agent"`.

## Install & Test

```bash
./bin/install
```
