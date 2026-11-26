# ScreenLens

An Android "Circle to Search"-style on-screen AI overlay and Settings panel plugin for [Omarchy](https://omarchy.org) (`io.github.cgranier.screenlens`).

Summon ScreenLens over any window or workspace, circle/drag a region or select on-screen OCR text, dictate or type a question, and stream fast answers directly from your preferred AI provider—or hand the entire visual context straight off to your Omarchy coding agent.

> **Public Beta (`v0.9.0`):** ScreenLens is in active beta for early Omarchy testers. Bug reports and ideas are very welcome in [Issues](https://github.com/cgranier/screenlens/issues).

## Features

- **Instant On-Screen Overlay:** Summon via hotkey (`Super + Alt + A` by default) or right-click the bar icon (`󰍉`) without flicker.
- **Circle / Lasso & Region Crop:** Drag freely around anything on screen to crop and ask about that exact area.
- **On-Screen Text Selection (OCR):** Runs Tesseract word-box OCR in the background as soon as the overlay opens; press `Tab` (or click **Select Text**) to highlight any visible text on screen, copy it (`Ctrl+C`), or ask AI about it.
- **Quick-Action Chips (`Alt+1..4`):** One-click **Explain**, **Summarize**, **Translate** (to your configured target language), and **Extract Text**.
- **Superwhisper Voice Input (`Ctrl+M`):** Optional hands-free dictation straight into the prompt bar, with automatic deduplication when Superwhisper auto-paste is enabled.
- **Hybrid AI Backend + Agent Handoff:**
  - Streams fast direct Vision responses from **Google Gemini**, **Anthropic Claude**, **OpenAI**, or local **Ollama**.
  - Falls back automatically to your **Omarchy CLI Agent** (`claude`, `codex`, `agy`, `opencode`, `grok`, `gemini`, or your Omarchy default) when no direct API key is configured.
  - **Continue in Agent (`Ctrl+Shift+Enter`):** Hands the screenshot, cropped region, selected OCR text, and conversation history to your chosen CLI agent in a terminal.
- **Native Tabbed Settings Panel:** Left-click the `󰍉` bar widget (or click the gear icon inside the overlay) to configure:
  - **General:** Managed Hyprland keybind (with backup + `hyprctl` validation & rollback), default selection mode, theme (`System` / `Dark` / `Light` preserving your live Omarchy accent), and max image dimension.
  - **Providers:** Manage API keys (with direct links to provider key pages), discover live available models, select models, and run connection tests.
  - **Tasks:** Optional per-task provider/model routing (**General**, **Vision / Crop**, **Selected Text**, **Translate**) plus a dedicated **Continue in Agent** CLI selector.
  - **Language & OCR:** Pick your default translation language, toggle active Tesseract OCR packs, and install additional Arch `tesseract-data-*` packs directly from Settings.

## Requirements

- Omarchy with the Quattro shell (`omarchy-shell`) and Hyprland.
- Required packages: `grim`, `imagemagick`, `tesseract`, `tesseract-data-eng`, `wl-clipboard`, `python`, `jq`.
- Optional: [Superwhisper](https://superwhisper.com) for `Ctrl+M` voice dictation; `ollama` for local vision models.

## Install

```sh
omarchy plugin add https://github.com/cgranier/screenlens --enable
~/.config/omarchy/plugins/io.github.cgranier.screenlens/setup.sh
```

`setup.sh` checks required packages (offering to install any missing ones via `omarchy pkg add`) and asks before writing the managed Hyprland keybind (`SUPER + ALT + A`) to `~/.config/hypr/bindings.lua` and the `no_anim` layer rule to `~/.config/hypr/hyprland.lua`. Pass `--yes` to accept prompts automatically or `--no-binds` to skip Hyprland edits.

> **Tip:** If you skip `setup.sh`, you can still configure your hotkey anytime from the bar icon → **General → Keybinding** (applying a keybind also ensures the `no_anim` layer rule is set).

### Updating

```sh
omarchy plugin update io.github.cgranier.screenlens
omarchy restart shell
```

*(Restarting `omarchy-shell` ensures Qt 6 compiles updated QML fresh from disk.)*

### Uninstalling

```sh
omarchy plugin remove io.github.cgranier.screenlens
```

Then optionally delete:
- The `-- ScreenLens: begin.` … `-- ScreenLens: end.` block in `~/.config/hypr/bindings.lua`
- The `-- ScreenLens layer rule: begin.` … `-- ScreenLens layer rule: end.` block in `~/.config/hypr/hyprland.lua`
- `~/.config/omarchy/screenlens.json`

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Super + Alt + A` | Toggle ScreenLens overlay (customizable in Settings) |
| `Tab` | Switch between **Circle / Region** and **Select Text** modes |
| `Enter` | Send prompt / follow-up |
| `Ctrl + M` | Toggle Superwhisper voice dictation |
| `Alt + 1..4` | Explain / Summarize / Translate / Extract Text |
| `Ctrl + C` | Copy selected text, latest answer, or cropped region |
| `Ctrl + Shift + Enter` | Hand off screenshot + text + chat to your coding agent |
| `Esc` | Stop voice / cancel streaming / clear selection / dismiss |

Bar widget (`󰍉`): **Left-click** opens Settings, **Right-click** summons the ScreenLens overlay immediately.

## Privacy & Security

- **Local-only secret storage:** API keys saved in Settings are stored exclusively in `~/.config/omarchy/screenlens.json` with `0600` (owner-only) permissions—never in `~/.config/omarchy/shell.json` and never passed in command-line arguments. Environment variables (`GEMINI_API_KEY` / `GOOGLE_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OLLAMA_HOST`) are also auto-detected.
- **No telemetry:** Screenshots and prompts are sent only to the AI provider or local CLI you explicitly choose. Temporary captures live in `/tmp` and are never uploaded elsewhere.
- **Safe QML rendering:** All dynamic text is rendered through a plain-text wrapper (`PlainText`) to prevent markup injection inside the shell process.

## Development & Testing

```sh
omarchy plugin validate .
node tests/test_logic.mjs
python3 -m unittest -v tests/test_scripts.py tests/test_config.py tests/test_providers.py tests/test_ocr_langs.py
```

For local development installs from a working checkout:

```sh
./bin/install
```

## License

MIT — see [LICENSE](LICENSE).
