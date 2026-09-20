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
            echo "usage: apply.sh [--on-launch] [--probe] [--timeout=СЕК]"
            echo "  --on-launch  дождаться запуска игры, положить перевод после"
            echo "               проверок лаунчера, убрать после выхода"
            echo "  --probe      то же плюс inotify-лог обращений движка к файлам"
            echo "  без флагов   разложить файлы и выйти (только для отладки:"
            echo "               лаунчер сочтёт их лишними и потребует обновление)"
            exit 0 ;;
        *) echo "неизвестный аргумент: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BUNDLE_DIR="$(dirname "$SCRIPT_DIR")/bundle"
OVERRIDES="$SCRIPT_DIR/overrides.str"
RENAMES="$SCRIPT_DIR/renames.txt"

# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=/dev/null
[ -f "$SCRIPT_DIR/config.local.sh" ] && source "$SCRIPT_DIR/config.local.sh"

hon_require python3 pgrep || exit 1

if ! hon_detect; then
    echo "Игра не найдена. Задай пути в linux/config.local.sh:" >&2
    echo '  HON_GAME_DIR=".../AppData/Local/Juvio/heroes of newerth"' >&2
    echo '  HON_DOCS_DIR=".../Documents/Juvio/Heroes of Newerth"' >&2
    exit 1
fi

if [ ! -f "$HON_GAME_DIR/resources0.jz" ]; then
    echo "В $HON_GAME_DIR нет resources0.jz - это не каталог игры." >&2
    exit 1
fi

echo "Игра:    $HON_GAME_DIR"
echo "Конфиги: $HON_DOCS_DIR"

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
    [ -f "$orig" ] || { echo "  нет в архиве игры: ${base}_en.str" >&2; continue; }
    [ -f "$ru" ] || { echo "  нет в bundle/: ${base}_en.str" >&2; continue; }
    python3 "$SCRIPT_DIR/lib/honru.py" merge "$orig" "$ru" "$STAGE/${base}_en.str" "$OVERRIDES" "$RENAMES"
done

# host_locale=en обязателен: русский текст подменяет собой английский,
# локали ru в игре нет
STARTUP="$HON_DOCS_DIR/startup.cfg"
if [ -f "$STARTUP" ]; then
    [ -f "$STARTUP.honru-bak" ] || cp -p "$STARTUP" "$STARTUP.honru-bak"
    python3 "$SCRIPT_DIR/lib/honru.py" cfg "$STARTUP" \
        'host_locale=en' 'host_backuplocale=en' 'fs_disablemods=false'
else
    echo "  startup.cfg появится после первого входа в игру - запусти скрипт ещё раз"
fi

# Без очистки часть строк останется в кеше на английском
for cache in "$HON_DOCS_DIR/filecache" "$HON_DOCS_DIR/webcache"; do
    [ -d "$cache" ] || continue
    find "$cache" -mindepth 1 -delete 2>/dev/null || true
    echo "  кеш очищен: $(basename "$cache")"
done

if [ "$ON_LAUNCH" = "1" ]; then
    echo
    python3 "$SCRIPT_DIR/lib/honru.py" onlaunch \
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
echo "Файлов записано: $copied"
