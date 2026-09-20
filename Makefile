# Русификатор HoN для Linux. make help - список целей.

UPSTREAM     ?= upstream
UPSTREAM_URL ?= https://github.com/Xyling12/HoN_RU_Pack.git
BRANCH       ?= master
APPLY        := ./linux/apply.sh

.PHONY: help run probe uninstall update diff-upstream launch-options untranslated

help:
	@echo 'Цели:'
	@echo '  make run             дождаться запуска игры и применить перевод'
	@echo '  make probe           то же плюс inotify-лог обращений движка'
	@echo '  make uninstall       убрать перевод и вернуть startup.cfg'
	@echo '  make update          подтянуть свежий bundle/ из апстрима'
	@echo '  make diff-upstream   показать, что изменилось в апстриме'
	@echo '  make launch-options  строка для Steam -> Свойства -> Параметры запуска'
	@echo '  make untranslated    что осталось без перевода (GROUP=предметы - детали)'

run:
	$(APPLY) --on-launch

probe:
	$(APPLY) --probe

uninstall:
	./linux/uninstall.sh

# Забираем только bundle/, не мержа ветку целиком: в апстриме остаётся
# Windows-обвязка, удалённая из форка, и обычный merge тянул бы её обратно
# вместе с конфликтами "deleted by us / modified by them".
update: _need-upstream
	git fetch $(UPSTREAM) $(BRANCH)
	git checkout $(UPSTREAM)/$(BRANCH) -- bundle/
	@git diff --cached --stat -- bundle/ | tail -1 | grep -q . \
		&& echo 'bundle/ обновлён - проверь изменения и закоммить' \
		|| echo 'bundle/ уже актуален'

# База для сравнения - файлы из resources0.jz, поэтому нужна установленная игра
untranslated:
	@./linux/untranslated.sh '$(GROUP)'

diff-upstream: _need-upstream
	git fetch $(UPSTREAM) $(BRANCH)
	@git diff --stat HEAD $(UPSTREAM)/$(BRANCH) -- bundle/ | tail -20

launch-options:
	@echo "bash -c '$(CURDIR)/linux/apply.sh --on-launch & exec \"\$$@\"' -- %command%"

.PHONY: _need-upstream
_need-upstream:
	@git remote get-url $(UPSTREAM) >/dev/null 2>&1 || { \
		echo "Нет remote '$(UPSTREAM)'. Добавь его:"; \
		echo "  git remote add $(UPSTREAM) $(UPSTREAM_URL)"; \
		exit 1; }
