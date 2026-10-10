#!/usr/bin/env bash
# Adds (or removes) a "Setup > Monitor Manager" entry in the Omarchy menu.
#
#   ./menu-entry.sh install   # add the entry (default)
#   ./menu-entry.sh remove    # take it out again
#
# `omarchy plugin add` never runs plugin code, so this is a separate, opt-in
# step. It edits ~/.config/omarchy/extensions/omarchy-menu.jsonc, keeps a
# backup next to it, and restores that backup if the result would not parse
# (the menu ignores the whole file when it doesn't).
set -euo pipefail

id="io.github.fabiocuccaro.monitor-manager"
key="setup.monitor-manager"
file="${OMARCHY_MENU_EXTENSIONS:-$HOME/.config/omarchy/extensions/omarchy-menu.jsonc}"
entry="  \"$key\": {\"icon\":\"󰍹\",\"label\":\"Monitor Manager\",\"description\":\"Arrange displays visually\",\"aliases\":[\"monitor-manager\"],\"when\":\"[[ -f ~/.config/omarchy/plugins/$id/manifest.json ]]\",\"action\":\"omarchy-shell shell summon $id '{}'\"},"

# Same rules as the menu's own parser: drop full-line // comments and
# trailing commas, then it must be a JSON object.
check() {
  python3 - "$1" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
if not isinstance(json.loads(raw), dict):
    raise SystemExit("not a JSON object")
PY
}

install_entry() {
  mkdir -p "$(dirname "$file")"
  [[ -f $file ]] || printf '{\n}\n' >"$file"
  if grep -q "\"$key\"" "$file"; then
    echo "Menu entry already present in $file"
    return
  fi
  local backup="$file.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$file" "$backup"
  # Insert right after the opening brace: with its trailing comma the entry is
  # valid whatever follows it.
  awk -v entry="$entry" '!done && /^[[:space:]]*\{[[:space:]]*$/ { print; print entry; done = 1; next } { print }' \
    "$backup" >"$file"
  if ! grep -q "\"$key\"" "$file" || ! check "$file"; then
    cp -p "$backup" "$file"
    echo "Couldn't add the entry safely; $file left unchanged." >&2
    exit 1
  fi
  echo "Added Setup > Monitor Manager to the Omarchy menu (backup: $backup)"
}

remove_entry() {
  if [[ ! -f $file ]] || ! grep -q "\"$key\"" "$file"; then
    echo "No Monitor Manager menu entry found."
    return
  fi
  local backup="$file.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$file" "$backup"
  grep -v "\"$key\"" "$backup" >"$file"
  if ! check "$file"; then
    cp -p "$backup" "$file"
    echo "Couldn't remove the entry safely; $file left unchanged." >&2
    exit 1
  fi
  echo "Removed the Monitor Manager menu entry (backup: $backup)"
}

case "${1:-install}" in
  install) install_entry ;;
  remove) remove_entry ;;
  *) echo "usage: $0 [install|remove]" >&2; exit 2 ;;
esac
