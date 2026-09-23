#!/usr/bin/env bash
# Русификатор HoN для Linux (Proton/Wine). Только перевод: без фонового
# агента, обращений в сеть и баннеров. Подробности - linux/README.md.
#
# Собирает перевод в Juvio/extensions/resources0.jz и, если передана команда
# запуска игры, запускает её с -mod. Так его вызывает Steam:
#   '/путь/linux/apply.sh' %command%
# Steam подставляет %command% пустым и дописывает настоящую команду в конец
# строки, поэтому она приходит сюда аргументами.

set -euo pipefail

case "${1:-}" in
    -h|--help)
        echo "usage: apply.sh [команда запуска игры...]"
        echo "  без аргументов  только собрать перевод"
        echo "  с командой      собрать и запустить игру с -mod"
        exit 0 ;;
    --on-launch|--probe)
        # Прежняя строка запуска: bash -c 'apply.sh --on-launch & exec "$@"'.
        # Игру она запустит и без нас, но уже на английском
        echo "Устаревшие параметры запуска. Выполни make launch-options и" >&2
        echo "замени строку в Steam -> Свойства -> Параметры запуска." >&2
        exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")/bundle"

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/config.local.sh" ] && source "$SCRIPT_DIR/config.local.sh"

# Любая ошибка сборки не должна мешать играть: запускаем игру без мода,
# на английском и с обычным профилем. ERR ловит и неожиданные падения
GAME=("$@")
STAGE=""
play_english() {
    trap - ERR EXIT
    [ -n "$STAGE" ] && rm -rf "$STAGE"
    [ ${#GAME[@]} -gt 0 ] || exit 1
    echo "Перевод не применён, игра запускается на английском." >&2
    exec "${GAME[@]}"
}
trap play_english ERR

hon_require python3 || play_english

if ! hon_detect; then
    echo "Игра не найдена. Задай пути в linux/config.local.sh:" >&2
    echo '  HON_GAME_DIR=".../AppData/Local/Juvio/heroes of newerth"' >&2
    echo '  HON_DOCS_DIR=".../Documents/Juvio/Heroes of Newerth"' >&2
    play_english
fi

echo "Игра:    $HON_GAME_DIR"
echo "Конфиги: $HON_DOCS_DIR"

hon_remove_legacy

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# База берётся из архива игры, а не из bundle/: файл из мода подменяет
# архивный целиком, поэтому ключи, которых нет в bundle/, иначе пропали бы
# из игры вместе с английским текстом. Заодно новые строки из патчей игры
# подхватываются сами
hon_extract_base "$STAGE/base" || play_english

echo
staged=()
for base in "${HON_STR_BASES[@]}"; do
    ru="$BUNDLE_DIR/${base}_en.str"
    orig="$STAGE/base/${base}_en.str"
    [ -f "$orig" ] || { echo "  нет в архиве игры: ${base}_en.str" >&2; continue; }
    [ -f "$ru" ] || { echo "  нет в bundle/: ${base}_en.str" >&2; continue; }
    python3 "$SCRIPT_DIR/lib/honru.py" merge "$orig" "$ru" "$STAGE/${base}_en.str"
    staged+=("$STAGE/${base}_en.str")
done
[ ${#staged[@]} -gt 0 ] || play_english

ARCHIVE="$(hon_mod_archive)"
mkdir -p "$(dirname "$ARCHIVE")"
python3 "$SCRIPT_DIR/lib/honru.py" pack "$ARCHIVE" "${staged[@]}" || play_english

# Профиль: ссылка extensions -> "Heroes of Newerth", чтобы с модом игра
# работала с теми же настройками и тем же входом в аккаунт
mkdir -p "$HON_DOCS_DIR"
LINK="$(hon_profile_link)"
TARGET="$(basename "$HON_DOCS_DIR")"
if [ -L "$LINK" ]; then
    [ "$(readlink "$LINK")" = "$TARGET" ] || ln -sfn "$TARGET" "$LINK"
else
    if [ -e "$LINK" ]; then
        # Настоящий каталог остаётся после запуска с модом без ссылки.
        # Не удаляем: вдруг там что-то нужное
        mv "$LINK" "$LINK.honru-old-$(date +%Y%m%d-%H%M%S)"
        echo "  прежний профиль $HON_MOD отложен рядом с суффиксом .honru-old"
    fi
    ln -s "$TARGET" "$LINK"
    echo "  профиль $HON_MOD -> $TARGET"
fi

# host_locale=en обязателен: русский текст подменяет собой английский,
# локали ru в игре нет
STARTUP="$HON_DOCS_DIR/startup.cfg"
if [ -f "$STARTUP" ]; then
    python3 "$SCRIPT_DIR/lib/honru.py" cfg "$STARTUP" "$STARTUP.honru-orig" \
        'host_locale=en' 'host_backuplocale=en' 'fs_disablemods=false'
fi

# Кеш чистим только при смене строк: там лежат отрисованные шрифтовые
# атласы, и снос на каждом запуске просто замедляет старт игры
STAMP_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hon-ru"
STAMP="$STAMP_DIR/strings.sha"
NOW_SHA="$(cat "${staged[@]}" | sha256sum | cut -d' ' -f1)"
if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$NOW_SHA" ]; then
    for cache in "$HON_DOCS_DIR/filecache" "$HON_DOCS_DIR/webcache"; do
        [ -d "$cache" ] || continue
        find "$cache" -mindepth 1 -delete 2>/dev/null || true
        echo "  кеш очищен: $(basename "$cache")"
    done
    mkdir -p "$STAMP_DIR"
    printf '%s\n' "$NOW_SHA" > "$STAMP"
fi

trap - ERR
[ ${#GAME[@]} -gt 0 ] || exit 0

# Proton передаёт juvio.exe всё, что стоит после него в командной строке.
# Апдейтер и движок живут в одном процессе, так что проверка обновлений
# проходит как обычно
echo
MOD="$(hon_mod_arg)"
rm -rf "$STAGE"
trap - EXIT
exec "${GAME[@]}" -mod "$MOD"
