# Русификатор HoN для Linux. make help - список целей.

APPLY := ./linux/apply.sh

.PHONY: help build uninstall launch-options untranslated lint

help:
	@echo 'Цели:'
	@echo '  make build           собрать перевод без запуска игры'
	@echo '  make uninstall       убрать перевод и вернуть startup.cfg'
	@echo '  make launch-options  строка для Steam -> Свойства -> Параметры запуска'
	@echo '  make untranslated    что осталось без перевода (GROUP=предметы - детали)'
	@echo '  make lint            проверить bundle/ на дефекты перевода'

build:
	$(APPLY)

uninstall:
	./linux/uninstall.sh

# Эталон строк берётся из resources0.jz, поэтому нужна установленная игра
lint:
	@./linux/lint.sh $(LIMIT)

untranslated:
	@./linux/untranslated.sh '$(GROUP)'

# Steam подставляет %command% пустым и дописывает команду игры в конец
# строки - она приходит в apply.sh аргументами
launch-options:
	@echo "'$(CURDIR)/linux/apply.sh' %command%"
