#!/usr/bin/env bash
# Готовит ветку с переводами для PR в апстрим.
#
# Ветка растёт от upstream/master и содержит только изменения bundle/:
# ни Linux-порта, ни удалённой Windows-обвязки, ни overrides.str - апстриму
# нужен перевод, а не наша сборка.

set -euo pipefail

UPSTREAM="${UPSTREAM:-upstream}"
BRANCH="${BRANCH:-master}"
NAME="${1:-}"

[ -n "$NAME" ] || { echo "usage: pr-branch.sh <имя-ветки>" >&2; exit 1; }

git diff --quiet && git diff --cached --quiet || {
    echo "Есть незакоммиченные изменения - закоммить их сначала." >&2
    exit 1
}

SOURCE="$(git rev-parse --abbrev-ref HEAD)"
git fetch "$UPSTREAM" "$BRANCH"

git checkout -q -b "$NAME" "$UPSTREAM/$BRANCH"
git checkout "$SOURCE" -- bundle/

if git diff --cached --quiet; then
    echo "Переводы не отличаются от апстрима - отправлять нечего."
    git checkout -q "$SOURCE"
    git branch -q -D "$NAME"
    exit 0
fi

git diff --cached --stat
echo
echo "Ветка $NAME готова. Дальше:"
echo "  git commit -m 'translate: ...'   # только bundle/, оно уже в индексе"
echo "  (git add -A здесь не делай: .gitignore апстрима не знает про"
echo "   .idea и __pycache__, они попадут в PR)"
echo "  git push origin $NAME"
echo "  открой PR в $UPSTREAM/$BRANCH на github"
echo "Вернуться к работе: git checkout $SOURCE"
