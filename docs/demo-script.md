# ScreenLens — Overlay Demo Video Script (~28s)

A tight, single-take demo storyboard for recording ScreenLens on Omarchy (e.g. with **Reel** at 1080p / 60fps).

## Setup Before Recording
- Switch to a clean workspace with **two visual windows tiled side-by-side**:
  - **Left:** A webpage, diagram, chart, or foreign-language article/code error.
  - **Right:** A clean terminal or code file.
- Optional: enable Hyprland animations (`omarchy toggle animations`) so the edge-glow breath and panel entrances show smoothly.
- Optional: set `theme` to `System` so the overlay matches your live Omarchy theme & accent.
- Make sure an API key (Gemini / Anthropic / OpenAI) is configured in Settings for 1–2s direct streaming.

## Shot List

| Time | Action | What Viewers See |
|---|---|---|
| **0:00 – 0:03** | Start on desktop, press **`Super + Alt + A`** | Instant **feathered edge glow**, recessed segmented top pill, and floating prompt bar over the live screen—zero flicker. |
| **0:03 – 0:08** | **Freehand circle** a diagram, UI element, or error block | Luminous 4-layer lasso stroke snapping into the **machined L-bracket crop cutout**, `W × H` pixel badge, and floating action bar. |
| **0:08 – 0:14** | Click **Explain** (`Alt+1`) *(or dictate with `Ctrl+M` for 2s)* | Shimmer loading bar → fast streamed **structured answer** (headings, accent bullets, recessed code block with one-click **Copy**). |
| **0:14 – 0:19** | Press **`Tab`** (Select Text mode), drag over a foreign sentence or error line, press **`Alt+3` (Translate)** | Live Tesseract OCR word highlights lighting up on screen → instant translation into your configured target language. |
| **0:19 – 0:24** | Click **Continue in Agent** (`Ctrl+Shift+Enter`) | Overlay dismisses cleanly and your terminal opens with the screenshot, crop, selected text, and prior chat already handed off to your coding agent. |
| **0:24 – 0:28** | Click the **ScreenLens viewfinder icon** in the top bar and tap **`Tab`** across tabs | Shows the Reel-inspired Settings panel (General / Providers / Tasks / Language & OCR), provider status dots, and per-task model routing. |

## Publishing to GitHub README
- Record with **Reel** (optional: brief `1.5×` zoom on the lasso & Settings panel).
- Drag the exported `.mp4` into a GitHub issue or PR comment on `cgranier/screenlens` to generate a hosted `user-attachments` video URL, then paste that URL into `README.md` for native inline autoplay.
