#!/usr/bin/env bash
# Убирает русификатор. resources0.jz при установке не трогался, откатывать
# в самой игре нечего.
#
# Заодно чистит каталог игры от файлов прежних версий скрипта: если лаунчер
# зациклился на "требуется обновление", этот скрипт чинит такое состояние.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/config.local.sh" ] && source "$SCRIPT_DIR/config.local.sh"

if ! hon_detect; then
    echo "Игра не найдена - удалять нечего." >&2
    exit 1
fi

hon_remove_legacy

ARCHIVE="$(hon_mod_archive)"
if [ -f "$ARCHIVE" ]; then
    rm -f "$ARCHIVE" "$ARCHIVE.tmp"
    echo "  архив перевода удалён"
fi
rmdir "$(dirname "$ARCHIVE")" 2>/dev/null || true

# Только ссылку: настоящий каталог с таким именем мог завести сам игрок
LINK="$(hon_profile_link)"
if [ -L "$LINK" ]; then
    rm -f "$LINK"
    echo "  ссылка профиля удалена"
fi

# Возвращаем только те значения, которые меняли сами: остальное в этом
# файле - настройки игрока, накопленные с момента установки
STARTUP="$HON_DOCS_DIR/startup.cfg"
if [ -f "$STARTUP" ]; then
    python3 "$SCRIPT_DIR/lib/honru.py" cfg-restore "$STARTUP" "$STARTUP.honru-orig"
fi

# Убираем старый бэкап целого файла, если остался от прежних версий
rm -f "$STARTUP.honru-bak"

for cache in "$HON_DOCS_DIR/filecache" "$HON_DOCS_DIR/webcache"; do
    [ -d "$cache" ] && find "$cache" -mindepth 1 -delete 2>/dev/null || true
done
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/hon-ru/strings.sha"

echo "Готово. Не забудь убрать apply.sh из параметров запуска в Steam."
