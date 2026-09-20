#!/usr/bin/env bash
# Поиск установленной игры. Подключается через source из apply.sh и uninstall.sh.
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

# Логи апдейтера: по ним ловим момент, когда лаунчер передал управление движку
hon_logdir() {
    printf '%s\n' "${HON_LOG_DIR:-$(dirname "$HON_GAME_DIR")/logs}"
}

# Движок запрашивает /stringtables/interface.str и сам подставляет суффикс
# локали, а в архиве лежат только *_en.str - кладём оба варианта
HON_STR_SUFFIXES=("_en.str" ".str")
HON_STR_BASES=(entities interface client_messages game_messages bot_messages)
