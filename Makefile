# Русификатор HoN для Linux. make help - список целей.

APPLY := ./linux/apply.sh

.PHONY: help run probe uninstall launch-options untranslated lint

help:
	@echo 'Цели:'
	@echo '  make run             дождаться запуска игры и применить перевод'
	@echo '  make probe           то же плюс inotify-лог обращений движка'
	@echo '  make uninstall       убрать перевод и вернуть startup.cfg'
	@echo '  make launch-options  строка для Steam -> Свойства -> Параметры запуска'
	@echo '  make untranslated    что осталось без перевода (GROUP=предметы - детали)'
	@echo '  make lint            проверить bundle/ на дефекты перевода'

run:
	$(APPLY) --on-launch

probe:
	$(APPLY) --probe

uninstall:
	./linux/uninstall.sh

# Эталон строк берётся из resources0.jz, поэтому нужна установленная игра
lint:
	@./linux/lint.sh $(LIMIT)

untranslated:
	@./linux/untranslated.sh '$(GROUP)'

launch-options:
	@echo "bash -c '$(CURDIR)/linux/apply.sh --on-launch & exec \"\$$@\"' -- %command%"
