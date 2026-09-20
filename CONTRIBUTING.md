# Как править перевод

## Структура

```
bundle/                 файлы перевода, копия апстрима - правь через overrides
|-- entities_en.str     умения, предметы, герои
|-- interface_en.str    интерфейс, меню, настройки
|-- client_messages_en.str
|-- game_messages_en.str
`-- bot_messages_en.str

linux/                  порт под Linux
|-- apply.sh            установка и режим --on-launch
|-- uninstall.sh        откат
|-- config.sh           поиск игры в wine-префиксах
|-- overrides.str       локальные правки строк
`-- lib/                honru.py (мерж, startup.cfg), probe.py (inotify)

docs/                   правила перевода
```

## Свои правки

Не трогай `bundle/` напрямую - иначе `make update` будет конфликтовать.
Вместо этого добавь строку в `linux/overrides.str`:

```
interface:main_label_username	Имя пользователя
```

Формат: `<файл>:<ключ><TAB><значение>`, где `<файл>` - имя без `_en.str`.
Комментарии через `//`.

Проверить: `make run`, затем запустить игру.

## Формат .str

`КЛЮЧ<TAB>ЗНАЧЕНИЕ`, кодировка UTF-8 (часть файлов с BOM), переводы строк CRLF.
Менять кодировку нельзя - движок перестанет читать файл. `honru.py` сохраняет
её автоматически.

Цветовые коды вида `^g ... ^*` и подстановки `{100,150,200}` переносятся как есть.

Стиль и терминология: [docs/TRANSLATION_GUIDE.md](docs/TRANSLATION_GUIDE.md),
предметы отдельно - [docs/ITEMS_GUIDE.md](docs/ITEMS_GUIDE.md).
