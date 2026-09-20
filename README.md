# hon-ru-linux

Русский перевод Heroes of Newerth (HoN Reborn) для Linux: Proton, Lutris,
Bottles, чистый wine.

Форк [Xyling12/HoN_RU_Pack](https://github.com/Xyling12/HoN_RU_Pack). Здесь
**только перевод**: без фонового агента, обращений в сеть, баннеров и обхода
блокировок. Windows-обвязка удалена, перевод в `bundle/` берётся из апстрима.

## Установка

```sh
make launch-options
```

Скопируй выведенную строку в Steam -> ПКМ по игре -> Свойства -> Параметры
запуска. Всё: перевод применяется при каждом запуске и убирается после выхода.

Проверить вручную, не трогая Steam:

```sh
make run     # затем запусти игру обычным способом
```

Нужны `make`, `python3` и `pgrep`; для `make lint` и `make untranslated`
дополнительно `7z` (пакет p7zip).

Если игра не нашлась, создай `linux/config.local.sh` (он в `.gitignore`):

```sh
HON_GAME_DIR="/путь/до/AppData/Local/Juvio/heroes of newerth"
HON_DOCS_DIR="/путь/до/Documents/Juvio/Heroes of Newerth"
```

## Команды

| | |
|---|---|
| `make run` | применить перевод при запуске игры |
| `make probe` | то же плюс inotify-лог обращений движка к файлам |
| `make uninstall` | убрать перевод, вернуть `startup.cfg` |
| `make update` | подтянуть свежий `bundle/` из апстрима |
| `make diff-upstream` | посмотреть, что изменилось в апстриме |
| `make lint` | проверить `bundle/` на дефекты перевода |
| `make untranslated` | что осталось без перевода |
| `make pr NAME=...` | ветка с переводом для PR в апстрим |

`make lint` и `make untranslated` сверяются с установленной игрой: эталон строк
берётся из `resources0.jz`.

## Обновление

```sh
git remote add upstream https://github.com/Xyling12/HoN_RU_Pack.git   # один раз
make update
```

Забирается только `bundle/`, ветка целиком не мержится - иначе вернулась бы
удалённая Windows-обвязка.

## Удаление

```sh
make uninstall
```

Удаляет разложенные файлы и возвращает `startup.cfg` из бэкапа. После этого
убери строку из Launch Options.

Если лаунчер зациклился на "требуется обновление", значит в каталоге игры
остались файлы перевода - например, скрипт сняли до того, как он прибрался.
`make uninstall` это чинит.

## Что дальше

- Как это устроено и почему именно так: [linux/README.md](linux/README.md)
- Как править перевод: [CONTRIBUTING.md](CONTRIBUTING.md)

Переведены интерфейс, описания способностей и предметов, системные сообщения.
Имена героев, предметов и способностей намеренно оставлены английскими.
