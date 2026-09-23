#!/usr/bin/env bash
# Поиск установленной игры и общие пути. Подключается через source из скриптов linux/.
#
# Если автопоиск промахнулся - создай linux/config.local.sh (он в .gitignore):
#   HON_GAME_DIR="/путь/до/AppData/Local/Juvio/heroes of newerth"
#   HON_DOCS_DIR="/путь/до/Documents/Juvio/Heroes of Newerth"

# Корни Steam, включая библиотеки из libraryfolders.vdf и flatpak-установку
_hon_steam_roots() {
    local root vdf
    for root in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" \
                "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        [ -d "$root" ] && printf '%s\n' "$root"
        vdf="$root/steamapps/libraryfolders.vdf"
        [ -f "$vdf" ] && grep -oP '"path"\s+"\K[^"]+' "$vdf" 2>/dev/null
    done | sort -u
}

# Wine-префиксы, в которых стоит поискать игру
_hon_prefixes() {
    [ -n "${WINEPREFIX:-}" ] && printf '%s\n' "$WINEPREFIX"
    [ -n "${STEAM_COMPAT_DATA_PATH:-}" ] && printf '%s\n' "$STEAM_COMPAT_DATA_PATH/pfx"

    local root
    while IFS= read -r root; do
        printf '%s\n' "$root"/steamapps/compatdata/*/pfx
    done < <(_hon_steam_roots)

    # Lutris, Bottles, ручной wine
    printf '%s\n' "$HOME/.wine" \
        "$HOME/Games"/*/ \
        "$HOME/.local/share/lutris/prefixes"/* \
        "$HOME/.local/share/bottles/bottles"/* \
        "$HOME/.var/app/com.usebottles.bottles/data/bottles/bottles"/*
}

hon_detect() {
    [ -n "${HON_GAME_DIR:-}" ] && return 0

    # Под Proton внутренний пользователь всегда steamuser, в остальных
    # префиксах каталог называется именем системного пользователя
    local pfx user game
    while IFS= read -r pfx; do
        [ -d "$pfx/drive_c/users" ] || continue
        for user in "$pfx"/drive_c/users/*; do
            [ -d "$user" ] || continue
            game="$user/AppData/Local/Juvio/heroes of newerth"
            if [ -f "$game/resources0.jz" ]; then
                HON_GAME_DIR="$game"
                HON_DOCS_DIR="$user/Documents/Juvio/Heroes of Newerth"
                return 0
            fi
        done
    done < <(_hon_prefixes)

    return 1
}

# Перевод подключается модом: -mod "heroes of newerth;extensions" велит движку
# читать ещё и Juvio/extensions/resources0.jz поверх основного архива. Каталог
# лежит рядом с игрой, а не внутри неё, поэтому лаунчер его не проверяет
HON_MOD=extensions

hon_mod_archive() {
    printf '%s\n' "$(dirname "$HON_GAME_DIR")/$HON_MOD/resources0.jz"
}

# Аргумент для juvio.exe: основной каталог игры и мод поверх него
hon_mod_arg() {
    printf '%s;%s\n' "$(basename "$HON_GAME_DIR")" "$HON_MOD"
}

# Последний мод в -mod заодно выбирает профиль настроек: без ссылки игра
# завела бы пустой Documents/Juvio/extensions и разлогинила игрока
hon_profile_link() {
    printf '%s\n' "$(dirname "$HON_DOCS_DIR")/$HON_MOD"
}

# Убирает файлы, которые прежние версии скрипта клали прямо в каталог игры.
# Оставшись там, они отправляют лаунчер в вечное "требуется обновление"
hon_remove_legacy() {
    local target base suffix removed=0
    for target in "$HON_GAME_DIR/stringtables" "$HON_GAME_DIR/game/stringtables" \
                  "$HON_DOCS_DIR/stringtables" "$HON_DOCS_DIR/game/stringtables"; do
        [ -d "$target" ] || continue
        # Только свои файлы: чужие моды в этих каталогах не трогаем
        for base in "${HON_STR_BASES[@]}"; do
            for suffix in _en.str .str _ru.str _th.str; do
                [ -f "$target/$base$suffix" ] || continue
                rm -f "$target/$base$suffix"
                removed=$((removed + 1))
            done
        done
        rmdir "$target" 2>/dev/null || true
    done
    rmdir "$HON_GAME_DIR/game" "$HON_DOCS_DIR/game" 2>/dev/null || true
    [ "$removed" -eq 0 ] || echo "  убраны файлы прежней версии из каталога игры: $removed"
}

# Проверяет, что нужные утилиты на месте
hon_require() {
    local tool missing=0
    for tool in "$@"; do
        command -v "$tool" >/dev/null || { echo "Нужен $tool." >&2; missing=1; }
    done
    return $missing
}

# Извлекает англоязычные stringtables из resources0.jz в указанный каталог.
# Они нужны и как база для мержа, и как эталон для отчёта о пробелах.
hon_extract_base() {
    local dst="$1" zip=""
    for candidate in 7z 7zz 7za; do
        command -v "$candidate" >/dev/null && { zip="$candidate"; break; }
    done
    if [ -z "$zip" ]; then
        echo "Нужен 7z (пакет p7zip) для чтения resources0.jz." >&2
        return 1
    fi
    if [ ! -f "$HON_GAME_DIR/resources0.jz" ]; then
        echo "Не найден архив игры: $HON_GAME_DIR/resources0.jz" >&2
        return 1
    fi
    mkdir -p "$dst"
    if ! "$zip" e "$HON_GAME_DIR/resources0.jz" "stringtables/*_en.str" \
            -o"$dst" -y >/dev/null 2>&1; then
        echo "Не удалось прочитать stringtables из resources0.jz." >&2
        return 1
    fi
}

HON_STR_BASES=(entities interface client_messages game_messages bot_messages)
