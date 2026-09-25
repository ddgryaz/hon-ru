#!/usr/bin/env bash
# Отчёт о непереведённых строках. Вызывается через `make untranslated`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")/bundle"

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/config.local.sh" ] && source "$SCRIPT_DIR/config.local.sh"

hon_require python3 || exit 1
hon_detect || { echo "Игра не найдена. Задай пути в linux/config.local.sh" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
hon_extract_base "$TMP" || exit 1

python3 "$(dirname "$SCRIPT_DIR")/tools/untranslated.py" "$TMP" "$BUNDLE_DIR" "${1:-}"
