# ScreenLens

An Android "Circle to Search"-style on-screen AI overlay and Settings panel plugin for [Omarchy](https://omarchy.org) (`io.github.cgranier.screenlens`).

Summon ScreenLens over any window or workspace, circle or box one or more regions, select live OCR text, ask out loud hands-free with Superwhisper, and stream fast answers directly from your preferred AI provider—or hand the entire visual context straight off to your Omarchy coding agent.

> **Public Beta (`v0.9.2`):** ScreenLens is in active beta for early Omarchy testers. Bug reports and ideas are very welcome in [Issues](https://github.com/cgranier/screenlens/issues).

![ScreenLens overlay comparing two pinned regions with live web grounding](docs/overlay-demo.png)

## Features

- **Instant On-Screen Overlay:** Summon via hotkey (`Super + Alt + A` by default) or right-click the bar icon without flicker.
- **Circle, Box & Multi-Region Selection:**
  - Switch between **Circle** (freehand lasso), **Box** (draggable rectangle marquee), and **Text** (live OCR selection) via the top bar or `Tab`.
  - Resize and reposition locked selections with live corner/edge handles.
  - Hold **`Shift + drag`** to pin up to 6 numbered regions (`#1`..`#6`) and ask about or compare them in a single prompt.
- **Instant On-Screen OCR Text Selection:** Runs Tesseract word-box OCR in the background as soon as the overlay opens; highlight any visible text, copy (`Ctrl+C`), extract text in 0 ms, or ask AI about it.
- **Quick-Access Voice Ask (`Super + Alt + V`):** Press one hotkey anywhere to capture your screen and immediately start Superwhisper dictation; press again (or `Enter`) to transcribe and auto-ask hands-free. Also supports in-overlay `Ctrl+M` dictation with late auto-paste deduplication.
- **Context-Aware Smart Quick Actions (`Alt+5..6`):** Zero-latency local detection surfaces high-contrast action pills when relevant:
  - **QR / Barcodes:** **Open QR Link** (strict `http://`/`https://` validation) or **Copy QR** (when `zbar` is installed).
  - **Errors & Stack Traces:** **Diagnose & Fix** for tracebacks, compiler errors, and HTTP 4xx/5xx failures.
  - **Tables:** **Extract Table** into a clean Markdown table + copyable fenced CSV block.
- **Standard Quick-Action Chips (`Alt+1..4`):** One-click **Explain**, **Summarize**, **Translate** (to your configured target language), and **Extract Text**.
- **Optional Live Web Search Grounding (`Ctrl+G`):** Toggle live web search per question (off by default) with a **`WEB`** badge on grounded answers.
- **Local Session History & Visual Resume (`Ctrl+H`):**
  - Accidentally hit `Esc`? Click **Resume** (or press `Ctrl+H`) to restore your previous conversation **and** its original screen snapshot, complete with OCR and a **Live Screen** toggle.
  - Browse, filter, copy, resume, hand off to agent, or delete saved sessions in **Settings → History**.
  - Privacy-first & bounded: `0600` owner-only storage in `~/.local/state/omarchy/screenlens/`, 24h default auto-expiry (`24h | 3d | 7d | 30d`), hard 10 MB frame cap, and a text-only toggle to disable saving snapshots completely.
- **Hybrid AI Backend + Agent Handoff:**
  - Streams fast direct Vision responses from **Google Gemini**, **Anthropic Claude**, **OpenAI**, or local **Ollama**.
  - Falls back automatically to your **Omarchy CLI Agent** (`claude`, `codex`, `agy`, `opencode`, `grok`, `gemini`, or your Omarchy default) when no direct API key is configured.
  - **Continue in Agent (`Ctrl+Shift+Enter`):** Hands the screenshot, cropped region, selected OCR text, and conversation history to your chosen CLI agent in a terminal.
- **Native Tabbed Settings Panel:** Left-click the bar widget (or click the gear icon inside the overlay) to configure:
  - **General:** Managed Hyprland keybinds (`Super + Alt + A` & Voice Ask `Super + Alt + V`, with backup + `hyprctl` validation & rollback), default selection mode, theme (`System` / `Dark` / `Light` preserving your live Omarchy accent), max image dimension, and session history retention/privacy controls.
  - **Providers:** Manage API keys (with direct links to provider key pages), discover live available models, select models, and run connection tests.
  - **Tasks:** Optional per-task provider/model routing (**General**, **Vision / Crop**, **Selected Text**, **Translate**) plus a dedicated **Continue in Agent** CLI selector.
  - **Language & OCR:** Pick your default translation language, toggle active Tesseract OCR packs, and install additional Arch `tesseract-data-*` packs directly from Settings.
  - **History:** Search recent conversations, inspect thumbnails & full threads, copy answers, resume visual context, hand off to your coding agent, or delete/clear history.

## Screenshots

### Context-Aware Table Extraction (Markdown + CSV)

![ScreenLens auto-detecting a table and extracting Markdown + CSV](docs/table-extract-demo.png)

### Settings Panel

![ScreenLens Settings panel on Omarchy](docs/settings-hero.png)

![ScreenLens Settings tabs — General, Providers, and Language & OCR](docs/settings-showcase.png)

## Requirements

- Omarchy with the Quattro shell (`omarchy-shell`) and Hyprland.
- Required packages: `grim`, `imagemagick`, `tesseract`, `tesseract-data-eng`, `wl-clipboard`, `python`, `jq`.
- Optional: [Superwhisper](https://superwhisper.com) for voice dictation & Voice Ask; `zbar` (`zbarimg`) for offline QR/barcode decoding; `ollama` for local vision models.

## Install

```sh
omarchy plugin add https://github.com/cgranier/screenlens --enable
~/.config/omarchy/plugins/io.github.cgranier.screenlens/setup.sh
```

`setup.sh` checks required packages (offering to install any missing ones via `omarchy pkg add`) and asks before writing the managed Hyprland keybinds (`SUPER + ALT + A`, plus optional `SUPER + ALT + V` from Settings) to `~/.config/hypr/bindings.lua` and the `no_anim` layer rule to `~/.config/hypr/hyprland.lua`. Pass `--yes` to accept prompts automatically or `--no-binds` to skip Hyprland edits.

> **Tip:** If you skip `setup.sh`, you can still configure both hotkeys anytime from the bar icon → **General → Keybinding** (applying a keybind also ensures the `no_anim` layer rule is set).

### Updating

ScreenLens checks its git remote automatically (cached for an hour; toggleable under **Settings → General**) and shows an **`↑ N`** badge in the bottom-right footer of the Settings panel whenever new commits are available. Click the badge—or press **`Shift+U`** while Settings is open—to review incoming commits, run `omarchy plugin update`, and restart `omarchy-shell` automatically.

You can also update manually from a terminal:

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
- `~/.config/omarchy/screenlens.json` and `~/.local/state/omarchy/screenlens/`

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Super + Alt + A` | Toggle ScreenLens overlay (customizable in Settings) |
| `Super + Alt + V` | Quick-access Voice Ask — capture, dictate, and auto-ask (configurable in Settings) |
| `Tab` / `Shift + Tab` | Cycle **Circle** / **Box** / **Text** selection modes |
| `Shift + drag` | Pin an additional region (`#1`..`#6`) in Circle or Box mode |
| `Enter` | Send prompt / follow-up (or stop & ask while voice recording) |
| `Ctrl + G` | Toggle live Web Search grounding |
| `Ctrl + M` | Toggle Superwhisper voice dictation inside overlay |
| `Ctrl + H` | Resume most recent saved conversation (when chat is empty) |
| `Alt + 1..4` | Explain / Summarize / Translate / Extract Text |
| `Alt + 5..6` | Trigger detected Smart Context Action (QR / Diagnose / Extract Table) |
| `Ctrl + C` | Copy selected text, latest answer, or cropped region |
| `Ctrl + Shift + Enter` | Hand off screenshot + text + chat to your coding agent |
| `Esc` | Stop voice / cancel streaming / clear selection / dismiss |

Bar widget: **Left-click** opens Settings (`c` captures, `v` launches Voice Ask), **Right-click** summons the ScreenLens overlay immediately.

## Privacy & Security

- **Local-only secret storage:** API keys saved in Settings are stored exclusively in `~/.config/omarchy/screenlens.json` with `0600` (owner-only) permissions—never in `~/.config/omarchy/shell.json`, never in session history, and never passed in command-line arguments. Environment variables (`GEMINI_API_KEY` / `GOOGLE_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OLLAMA_HOST`) are also auto-detected.
- **Bounded, owner-only history:** Saved sessions and optional compressed frames live in `0600` files under `0700 ~/.local/state/omarchy/screenlens/`, expire automatically (24h default), enforce a hard 10 MB total image cap, and can be set to text-only or disabled altogether in **Settings → General**.
- **No telemetry:** Screenshots and prompts are sent only to the AI provider or local CLI you explicitly choose.
- **Safe QML rendering:** All dynamic text is rendered through a plain-text wrapper (`PlainText`) to prevent markup injection inside the shell process.

## Development & Testing

```sh
omarchy plugin validate .
node tests/test_logic.mjs
python3 -m unittest -v tests/test_scripts.py tests/test_config.py tests/test_providers.py tests/test_ocr_langs.py tests/test_updater.py tests/test_history.py
```

For local development installs from a working checkout:

```sh
./bin/install
```

## License

MIT — see [LICENSE](LICENSE).
