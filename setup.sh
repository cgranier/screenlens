#!/bin/bash
set -euo pipefail

# Post-install setup helper for ScreenLens.
# Checks system dependencies and optionally adds the managed Hyprland keybind
# and no-animation layer rule (both safely fenced with backup + rollback).

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ID=$(jq -r '.id' "$ROOT_DIR/manifest.json")
ASSUME_YES=0
SKIP_BINDS=0
DEFAULT_KEYBIND="SUPER + ALT + A"

while (( $# > 0 )); do
  case "$1" in
    --yes|-y)
      ASSUME_YES=1
      shift
      ;;
    --no-binds)
      SKIP_BINDS=1
      shift
      ;;
    -h|--help)
      cat <<USAGE
Usage: $(basename "$0") [--yes] [--no-binds]

Checks ScreenLens dependencies, optionally installs missing Arch packages via
omarchy pkg add, and adds the managed Hyprland shortcut ($DEFAULT_KEYBIND) and
layer rule (with automatic backup and hyprctl validation).
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

confirm() {
  local prompt="$1"
  (( ASSUME_YES )) && return 0
  if [[ -t 0 && -t 1 ]]; then
    if command -v gum >/dev/null 2>&1; then
      gum confirm "$prompt"
    else
      local reply=""
      read -r -p "$prompt [y/N] " reply
      [[ $reply =~ ^[Yy]$ ]]
    fi
  else
    return 1
  fi
}

echo "==> Checking ScreenLens dependencies..."
MISSING_PKGS=()
check_cmd() {
  local bin="$1"
  local pkg="$2"
  if ! command -v "$bin" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
}

check_cmd grim grim
check_cmd magick imagemagick
check_cmd tesseract tesseract
check_cmd wl-copy wl-clipboard
check_cmd python3 python
check_cmd jq jq

if command -v tesseract >/dev/null 2>&1; then
  if ! tesseract --list-langs 2>&1 | grep -qx "eng"; then
    MISSING_PKGS+=("tesseract-data-eng")
  fi
else
  MISSING_PKGS+=("tesseract-data-eng")
fi

if (( ${#MISSING_PKGS[@]} > 0 )); then
  # Deduplicate package list while preserving order.
  UNIQUE_PKGS=()
  for p in "${MISSING_PKGS[@]}"; do
    skip=0
    for u in "${UNIQUE_PKGS[@]}"; do
      [[ "$u" == "$p" ]] && skip=1 && break
    done
    (( skip )) || UNIQUE_PKGS+=("$p")
  done
  echo "Missing packages: ${UNIQUE_PKGS[*]}"
  if confirm "Install missing packages with 'omarchy pkg add ${UNIQUE_PKGS[*]}'?"; then
    omarchy pkg add "${UNIQUE_PKGS[@]}"
  else
    echo "Skipping package install. Install them manually before using ScreenLens:"
    echo "  omarchy pkg add ${UNIQUE_PKGS[*]}"
  fi
else
  echo "All required dependencies are installed."
fi

if ! command -v superwhisper >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/superwhisper" ]]; then
  echo "Note: Superwhisper not found (optional — only needed for Ctrl+M voice input)."
fi

if (( ! SKIP_BINDS )); then
  echo ""
  echo "==> Hyprland shortcut & overlay layer rule"
  echo "  - Adds a fenced block to ~/.config/hypr/bindings.lua ($DEFAULT_KEYBIND -> $PLUGIN_ID)"
  echo "  - Adds a fenced no_anim layer rule to ~/.config/hypr/hyprland.lua (prevents layer-fade flicker)"
  if confirm "Apply managed Hyprland keybind ($DEFAULT_KEYBIND) and layer rule?"; then
    python3 "$ROOT_DIR/scripts/config.py" ensure-layer-rule --no-reload >/dev/null
    python3 "$ROOT_DIR/scripts/config.py" set-keybind "$DEFAULT_KEYBIND"
    echo "Applied Hyprland binding ($DEFAULT_KEYBIND) and layer rule."
  else
    echo "Skipped Hyprland config. You can configure the hotkey anytime in ScreenLens Settings."
  fi
fi

echo ""
echo "ScreenLens ($PLUGIN_ID) is ready!"
echo "  - Click the ScreenLens icon in the bar to open Settings and add an API key (optional)."
echo "  - Press $DEFAULT_KEYBIND (or right-click the bar icon) to summon ScreenLens."
