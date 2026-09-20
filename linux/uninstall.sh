#!/usr/bin/env bash
# Убирает русификатор. resources0.jz при установке не трогался, откатывать
# в самой игре нечего.
#
# Если лаунчер зациклился на "требуется обновление" - значит в каталоге игры
# остались файлы перевода; этот скрипт чинит такое состояние.

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

# Рабочий каталог один, остальные - от прежних версий скрипта
TARGETS=(
    "$HON_GAME_DIR/stringtables"
    "$HON_GAME_DIR/game/stringtables"
    "$HON_DOCS_DIR/stringtables"
    "$HON_DOCS_DIR/game/stringtables"
)
SUFFIXES=("_en.str" ".str" "_ru.str" "_th.str")

removed=0
for target in "${TARGETS[@]}"; do
    [ -d "$target" ] || continue
    # Только свои файлы: чужие моды в этих каталогах не трогаем
    for base in "${HON_STR_BASES[@]}"; do
        for suffix in "${SUFFIXES[@]}"; do
            f="$target/${base}${suffix}"
            [ -f "$f" ] && { rm -f "$f"; removed=$((removed + 1)); }
        done
    done
    rmdir "$target" 2>/dev/null || true
done
rmdir "$HON_GAME_DIR/game" "$HON_DOCS_DIR/game" 2>/dev/null || true
echo "Файлов удалено: $removed"

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

echo "Готово. Не забудь убрать apply.sh из Launch Options в Steam."
