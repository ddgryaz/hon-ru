#!/usr/bin/env bash
# Русификатор HoN для Linux (Proton/Wine). Только перевод: без фонового
# агента, обращений в сеть и баннеров. Подробности - linux/README.md.

set -euo pipefail

ON_LAUNCH=0
PROBE=0
TIMEOUT="${HON_TIMEOUT:-3600}"
GAME_PROCESS="${HON_GAME_PROCESS:-juvio.exe}"

for arg in "$@"; do
    case "$arg" in
        --on-launch) ON_LAUNCH=1 ;;
        --probe)     ON_LAUNCH=1; PROBE=1 ;;
        --timeout=*) TIMEOUT="${arg#*=}" ;;
        -h|--help)
            echo "usage: apply.sh [--on-launch] [--probe] [--timeout=SEC]"
            echo "  --on-launch  wait for the game, place the translation after the"
            echo "               launcher checks, remove it after exit"
            echo "  --probe      same plus an inotify log of engine file access"
            echo "  no flags     place the files and exit (debug only: the launcher"
            echo "               treats them as extra files and demands an update)"
            exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")/bundle"

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/config.local.sh" ] && source "$SCRIPT_DIR/config.local.sh"

hon_require python3 pgrep || exit 1

if ! hon_detect; then
    echo "Game not found. Set the paths in linux/config.local.sh:" >&2
    echo '  HON_GAME_DIR=".../AppData/Local/Juvio/heroes of newerth"' >&2
    echo '  HON_DOCS_DIR=".../Documents/Juvio/Heroes of Newerth"' >&2
    exit 1
fi

if [ ! -f "$HON_GAME_DIR/resources0.jz" ]; then
    echo "No resources0.jz in $HON_GAME_DIR - not a game directory." >&2
    exit 1
fi

echo "Game:    $HON_GAME_DIR"
echo "Configs: $HON_DOCS_DIR"

# Запоминаем лог до подготовки строк: из Steam лаунчер стартует одновременно
# со скриптом, и его новый лог иначе можно принять за старый
HON_BASELINE_LOG="$(ls -t "$(hon_logdir)"/*.log 2>/dev/null | head -n 1 || true)"
export HON_BASELINE_LOG
# По нему onlaunch поймёт, что лаунчер скачал патч в этом запуске
export HON_ARCHIVE="$HON_GAME_DIR/resources0.jz"
HON_ARCHIVE_STAMP="$(stat -c '%s/%Y' "$HON_ARCHIVE")"
export HON_ARCHIVE_STAMP

# Единственный каталог, откуда движок реально читает строки (проверено inotify).
# Лишние файлы рядом с игрой вредны: лаунчер считает по ним установку битой.
TARGET="$HON_GAME_DIR/stringtables"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# База берётся из архива игры, а не из bundle/: файл на диске подменяет
# архивный целиком, поэтому ключи, которых нет в bundle/, иначе пропали бы
# из игры вместе с английским текстом. Заодно новые строки из патчей игры
# подхватываются сами.
hon_extract_base "$STAGE/base" || exit 1

echo
for base in "${HON_STR_BASES[@]}"; do
    ru="$BUNDLE_DIR/${base}_en.str"
    orig="$STAGE/base/${base}_en.str"
    [ -f "$orig" ] || { echo "  not in game archive: ${base}_en.str" >&2; continue; }
    [ -f "$ru" ] || { echo "  not in bundle/: ${base}_en.str" >&2; continue; }
    python3 "$SCRIPT_DIR/lib/honru.py" merge "$orig" "$ru" "$STAGE/${base}_en.str"
done

# host_locale=en обязателен: русский текст подменяет собой английский,
# локали ru в игре нет
STARTUP="$HON_DOCS_DIR/startup.cfg"
if [ -f "$STARTUP" ]; then
    python3 "$SCRIPT_DIR/lib/honru.py" cfg "$STARTUP" "$STARTUP.honru-orig" \
        'host_locale=en' 'host_backuplocale=en' 'fs_disablemods=false'
else
    echo "  no startup.cfg yet, it appears after the first game start - run the script again"
fi

# Кеш чистим только при смене строк: там лежат отрисованные шрифтовые
# атласы, и снос на каждом запуске просто замедляет старт игры
STAMP_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hon-ru"
STAMP="$STAMP_DIR/strings.sha"
NOW_SHA="$(cat "$STAGE"/*_en.str | sha256sum | cut -d' ' -f1)"
if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$NOW_SHA" ]; then
    for cache in "$HON_DOCS_DIR/filecache" "$HON_DOCS_DIR/webcache"; do
        [ -d "$cache" ] || continue
        find "$cache" -mindepth 1 -delete 2>/dev/null || true
        echo "  cache cleared: $(basename "$cache")"
    done
    mkdir -p "$STAMP_DIR"
    printf '%s\n' "$NOW_SHA" > "$STAMP"
fi

if [ "$ON_LAUNCH" = "1" ]; then
    echo
    python3 -u "$SCRIPT_DIR/lib/honru.py" onlaunch \
        "$STAGE" "$(IFS=,; echo "${HON_STR_SUFFIXES[*]}")" "$(hon_logdir)" \
        "$TIMEOUT" "$GAME_PROCESS" "$PROBE" "$TARGET"
    exit 0
fi

mkdir -p "$TARGET"
copied=0
for base in "${HON_STR_BASES[@]}"; do
    staged="$STAGE/${base}_en.str"
    [ -f "$staged" ] || continue
    for suffix in "${HON_STR_SUFFIXES[@]}"; do
        dst="$TARGET/${base}${suffix}"
        if [ ! -f "$dst" ] || ! cmp -s "$staged" "$dst"; then
            cp -f "$staged" "$dst"
            copied=$((copied + 1))
        fi
    done
done
echo
echo "Files written: $copied"
