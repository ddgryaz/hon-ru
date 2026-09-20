#!/usr/bin/env bash
# Проверка bundle/ против установленной игры. Вызывается через `make lint`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")/bundle"

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/config.local.sh" ] && source "$SCRIPT_DIR/config.local.sh"

hon_require python3 || exit 1
hon_detect || { echo "Игра не найдена - эталон строк берётся из resources0.jz" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
hon_extract_base "$TMP" || exit 1

python3 "$SCRIPT_DIR/lib/lint.py" "$TMP" "$BUNDLE_DIR" \
    "$SCRIPT_DIR/overrides.str" "${1:-5}"
