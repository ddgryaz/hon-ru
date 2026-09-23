#!/usr/bin/env python3
"""Операции для linux/apply.sh: merge, pack, cfg.

Работаем с байтами: .str приходят в UTF-8 (часть с BOM) и всегда с CRLF,
а startup.cfg игра пишет в UTF-16LE. Перекодировать нельзя - движок
перестанет их читать.
"""
import sys
import os


def sniff(data):
    """Возвращает (кодировка, BOM) по сигнатуре в начале файла."""
    if data.startswith(b'\xff\xfe'):
        return 'utf-16-le', b'\xff\xfe'
    if data.startswith(b'\xfe\xff'):
        return 'utf-16-be', b'\xfe\xff'
    if data.startswith(b'\xef\xbb\xbf'):
        return 'utf-8', b'\xef\xbb\xbf'
    return 'utf-8', b''


def parse_str(data):
    """Разбирает .str в {ключ: значение}, сохраняя порядок.

    Обычно ключ отделён табуляторами, но в файлах игры 299 строк разделены
    пробелами (`map_showdown    Showdown`). Пропускать их нельзя: cmd_merge
    собирает файл заново из разобранных ключей, и всё нераспознанное просто
    исчезает из игры вместе с английским текстом.

    Таб проверяется первым, потому что ключ может содержать пробел
    (`Extra tooltip?`), а вот таба внутри ключа не бывает.
    """
    if data.startswith(b'\xef\xbb\xbf'):
        data = data[3:]
    out = {}
    for line in data.decode('utf-8', 'replace').replace('\r\n', '\n').split('\n'):
        if not line or line.startswith('//'):
            continue
        if '\t' in line:
            key, value = line.split('\t', 1)
        else:
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            key, value = parts
        out[key.strip()] = value.strip()
    return out


def lookup(key, ru, ru_lower):
    """Ищет перевод: точное совпадение, затем без учёта регистра."""
    return ru.get(key) or ru_lower.get(key.lower())


def cmd_merge(base_path, ru_path, dst):
    """Собирает файл строк: база из архива игры + русские значения сверху.

    База обязательно берётся из resources0.jz, а не из bundle/: файл на диске
    заменяет архивный целиком, без отката к нему по отсутствующим ключам.
    Если положить один bundle/, все ключи, которых в нём нет (а игра их
    добавляет с каждым патчем), исчезнут из интерфейса вместе с английским
    текстом. Пустые значения в bundle/ по той же причине игнорируются.
    """
    stem = os.path.basename(ru_path)
    for suffix in ('_en.str', '.str'):
        if stem.endswith(suffix):
            stem = stem[:-len(suffix)]
            break

    with open(base_path, 'rb') as fh:
        base_raw = fh.read()
    bom = b'\xef\xbb\xbf' if base_raw.startswith(b'\xef\xbb\xbf') else b''
    base = parse_str(base_raw)

    with open(ru_path, 'rb') as fh:
        ru = parse_str(fh.read())

    ru_lower = {}
    for k, v in ru.items():
        if v:
            ru_lower.setdefault(k.lower(), v)

    translated = kept = 0
    for key in base:
        value = lookup(key, ru, ru_lower)
        if value:
            base[key] = value
            translated += 1
        else:
            kept += 1

    lines = ['%s\t\t%s' % (k, v) for k, v in base.items()]
    with open(dst, 'wb') as fh:
        fh.write(bom + '\r\n'.join(lines).encode('utf-8'))

    print('  %-24s переведено %5d, на английском %4d'
          % (stem, translated, kept))


def cmd_cfg(path, pairs, save_to=''):
    """Выставляет SetSave "<имя>" "<значение>" в startup.cfg.

    Кодировка сохраняется как есть: игра пишет этот файл в UTF-16LE.

    Исходные значения запоминаются в отдельный файл, а не копией всего
    startup.cfg: игра держит в нём свои настройки (хоткеи, графику, звук) и
    постоянно их дописывает, поэтому откат целого файла через неделю вернул
    бы пользователя к состоянию на день установки.
    """
    with open(path, 'rb') as fh:
        data = fh.read()
    enc, bom = sniff(data)
    text = data[len(bom):].decode(enc)
    newline = '\r\n' if '\r\n' in text else '\n'
    lines = text.split(newline)

    changed = []
    previous = {}
    for name, value in pairs:
        want = 'SetSave "%s" "%s"' % (name, value)
        found = False
        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped.lower().startswith('setsave "%s"' % name.lower()):
                found = True
                if stripped != want:
                    previous[name] = stripped
                    lines[i] = want
                    changed.append('%s -> %s' % (name, value))
                break
        if not found:
            previous[name] = ''      # строки не было, при откате удалим
            insert_at = len(lines)
            while insert_at > 0 and not lines[insert_at - 1].strip():
                insert_at -= 1
            lines.insert(insert_at, want)
            changed.append('%s -> %s (добавлено)' % (name, value))

    if not changed:
        print('  startup.cfg: уже настроен, изменений нет')
        return

    # Пишем только то, что было до нас, и только при первом вмешательстве
    if save_to and previous and not os.path.exists(save_to):
        with open(save_to, 'w', encoding='utf-8') as fh:
            for name, line in previous.items():
                fh.write('%s\t%s\n' % (name, line))

    out = bom + newline.join(lines).encode(enc)
    tmp = path + '.tmp'
    with open(tmp, 'wb') as fh:
        fh.write(out)
    os.replace(tmp, path)
    for item in changed:
        print('  startup.cfg: %s' % item)


def cmd_cfg_restore(path, saved):
    """Возвращает в startup.cfg значения, сохранённые при установке."""
    if not os.path.exists(saved):
        print('  startup.cfg: нечего восстанавливать')
        return
    with open(saved, encoding='utf-8') as fh:
        previous = [l.rstrip('\n').split('\t', 1) for l in fh if l.strip()]

    with open(path, 'rb') as fh:
        data = fh.read()
    enc, bom = sniff(data)
    text = data[len(bom):].decode(enc)
    newline = '\r\n' if '\r\n' in text else '\n'
    lines = text.split(newline)

    restored = 0
    for name, original in previous:
        for i, line in enumerate(lines):
            if line.strip().lower().startswith('setsave "%s"' % name.lower()):
                if original:
                    lines[i] = original
                else:
                    lines.pop(i)
                restored += 1
                break

    with open(path + '.tmp', 'wb') as fh:
        fh.write(bom + newline.join(lines).encode(enc))
    os.replace(path + '.tmp', path)
    os.remove(saved)
    print('  startup.cfg: восстановлено значений: %d' % restored)


def cmd_pack(dst, files):
    """Упаковывает собранные .str в архив-мод для -mod "...;extensions".

    Внутри путь тот же, что в resources0.jz: stringtables/<имя>_en.str.
    Сжатие не используем: движок читает и несжатые записи (в самом
    resources0.jz такие есть), а zstd, которым жмёт игра, в zipfile есть
    только с Python 3.14. Пишем во временный файл и подменяем целиком,
    чтобы игра не застала архив недописанным.
    """
    import zipfile
    tmp = dst + '.tmp'
    with zipfile.ZipFile(tmp, 'w', compression=zipfile.ZIP_STORED) as zf:
        for path in files:
            zf.write(path, 'stringtables/' + os.path.basename(path))
    os.replace(tmp, dst)
    print('  архив перевода: %s (%d КБ)' % (dst, os.path.getsize(dst) // 1024))


def main():
    if len(sys.argv) < 2:
        sys.exit('usage: honru.py {merge,pack,cfg,cfg-restore} ...')
    if sys.argv[1] == 'merge':
        cmd_merge(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sys.argv[1] == 'pack':
        cmd_pack(sys.argv[2], sys.argv[3:])
    elif sys.argv[1] == 'cfg':
        pairs = [tuple(a.split('=', 1)) for a in sys.argv[4:]]
        cmd_cfg(sys.argv[2], pairs, sys.argv[3])
    elif sys.argv[1] == 'cfg-restore':
        cmd_cfg_restore(sys.argv[2], sys.argv[3])
    else:
        sys.exit('unknown subcommand: %s' % sys.argv[1])


if __name__ == '__main__':
    main()
