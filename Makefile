# Русификатор HoN для Linux. make help - список целей.

UPSTREAM     ?= upstream
UPSTREAM_URL ?= https://github.com/Xyling12/HoN_RU_Pack.git
BRANCH       ?= master
APPLY        := ./linux/apply.sh

.PHONY: help run probe uninstall update diff-upstream launch-options untranslated pr lint

help:
	@echo 'Цели:'
	@echo '  make run             дождаться запуска игры и применить перевод'
	@echo '  make probe           то же плюс inotify-лог обращений движка'
	@echo '  make uninstall       убрать перевод и вернуть startup.cfg'
	@echo '  make update          подтянуть свежий bundle/ из апстрима'
	@echo '  make diff-upstream   показать, что изменилось в апстриме'
	@echo '  make launch-options  строка для Steam -> Свойства -> Параметры запуска'
	@echo '  make untranslated    что осталось без перевода (GROUP=предметы - детали)'
	@echo '  make lint            проверить bundle/ на дефекты перевода'
	@echo '  make pr NAME=...     ветка с переводами для PR в апстрим'

run:
	$(APPLY) --on-launch

probe:
	$(APPLY) --probe

uninstall:
	./linux/uninstall.sh

# Трёхсторонний мерж, а не перезапись: наши переводы живут в bundle/ и
# должны пережить обновление
update: _need-upstream
	@UPSTREAM='$(UPSTREAM)' BRANCH='$(BRANCH)' ./linux/update-bundle.sh

# Ветка для PR в апстрим - только изменения bundle/
pr: _need-upstream
	@test -n '$(NAME)' || { echo 'Укажи имя: make pr NAME=translate-report-ui'; exit 1; }
	@UPSTREAM='$(UPSTREAM)' BRANCH='$(BRANCH)' ./linux/pr-branch.sh '$(NAME)'

# Эталон строк берётся из resources0.jz, поэтому нужна установленная игра
lint:
	@./linux/lint.sh $(LIMIT)

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
