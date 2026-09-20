#!/usr/bin/env bash
# Подтягивает bundle/ из апстрима, сохраняя наши правки перевода.
#
# Трёхсторонний мерж пофайлово, а не git merge всей ветки: в апстриме живёт
# Windows-обвязка, удалённая из форка, и обычный merge тянул бы её обратно
# вместе с конфликтами "deleted by us / modified by them".

set -euo pipefail

UPSTREAM="${UPSTREAM:-upstream}"
BRANCH="${BRANCH:-master}"

git rev-parse --verify -q HEAD >/dev/null || { echo "Нет коммитов." >&2; exit 1; }

if ! git diff --quiet -- bundle/ || ! git diff --cached --quiet -- bundle/; then
    echo "В bundle/ есть незакоммиченные правки - закоммить их перед обновлением." >&2
    exit 1
fi

git fetch "$UPSTREAM" "$BRANCH"
REMOTE="$UPSTREAM/$BRANCH"
BASE="$(git merge-base HEAD "$REMOTE")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

conflicts=0
changed=0
for path in $(git ls-tree -r --name-only "$REMOTE" -- bundle/); do
    ours="$path"
    if [ ! -f "$ours" ]; then
        # файла у нас нет - просто берём версию апстрима
        mkdir -p "$(dirname "$ours")"
        git show "$REMOTE:$path" > "$ours"
        changed=$((changed + 1))
        echo "  новый: $path"
        continue
    fi

    git show "$REMOTE:$path" > "$TMP/theirs" 2>/dev/null || continue
    if git cat-file -e "$BASE:$path" 2>/dev/null; then
        git show "$BASE:$path" > "$TMP/base"
    else
        : > "$TMP/base"
    fi

    if cmp -s "$ours" "$TMP/theirs"; then
        continue
    fi

    # merge-file правит первый файл на месте и возвращает число конфликтов
    cp "$ours" "$TMP/before"
    if git merge-file -L "наша версия" -L "общий предок" -L "апстрим" \
            "$ours" "$TMP/base" "$TMP/theirs"; then
        if cmp -s "$ours" "$TMP/before"; then
            continue    # апстрим не принёс ничего нового для этого файла
        fi
        echo "  обновлён: $path"
    else
        n=$?
        conflicts=$((conflicts + n))
        echo "  КОНФЛИКТ ($n) в $path - разреши вручную, ищи <<<<<<<" >&2
    fi
    changed=$((changed + 1))
done

if [ "$changed" -eq 0 ]; then
    echo "bundle/ уже актуален"
elif [ "$conflicts" -gt 0 ]; then
    echo "Файлов изменено: $changed, конфликтов: $conflicts"
    exit 1
else
    echo "Файлов изменено: $changed, конфликтов нет - проверь и закоммить"
fi
