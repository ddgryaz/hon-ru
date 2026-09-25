#!/usr/bin/env python3
"""Операции для linux/apply.sh: merge, cfg, onlaunch.

Работаем с байтами: .str приходят в UTF-8 (часть с BOM) и всегда с CRLF,
а startup.cfg игра пишет в UTF-16LE. Перекодировать нельзя - движок
перестанет их читать.
"""
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', '..', 'tools'))
from strfile import parse_str, lookup  # noqa: E402


def sniff(data):
    """Возвращает (кодировка, BOM) по сигнатуре в начале файла."""
    if data.startswith(b'\xff\xfe'):
        return 'utf-16-le', b'\xff\xfe'
    if data.startswith(b'\xfe\xff'):
        return 'utf-16-be', b'\xfe\xff'
    if data.startswith(b'\xef\xbb\xbf'):
        return 'utf-8', b'\xef\xbb\xbf'
    return 'utf-8', b''


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


def game_running(pattern):
    """Запущен ли процесс игры.

    Ищем по имени процесса, а не по командной строке: пути к игре содержат
    "Juvio", и поиск по -f находил сам этот скрипт.
    """
    import subprocess
    try:
        rc = subprocess.run(['pgrep', '-x', pattern],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL).returncode
        return rc == 0
    except OSError:
        return False


def main():
    if len(sys.argv) < 2:
        sys.exit('usage: honru.py {merge,cfg} ...')
    if sys.argv[1] == 'merge':
        cmd_merge(sys.argv[2], sys.argv[3], sys.argv[4])
    elif sys.argv[1] == 'onlaunch':
        cmd_onlaunch(sys.argv[2], sys.argv[8:], sys.argv[3].split(','),
                     sys.argv[4], float(sys.argv[5]), sys.argv[6],
                     sys.argv[7] == '1')
    elif sys.argv[1] == 'cfg':
        pairs = [tuple(a.split('=', 1)) for a in sys.argv[4:]]
        cmd_cfg(sys.argv[2], pairs, sys.argv[3])
    elif sys.argv[1] == 'cfg-restore':
        cmd_cfg_restore(sys.argv[2], sys.argv[3])
    else:
        sys.exit('unknown subcommand: %s' % sys.argv[1])



def cmd_onlaunch(stage, targets, suffixes, logdir, timeout, pattern, probe=False):
    """Кладёт перевод в окно между проверками лаунчера и стартом движка.

    Лаунчер считает установку битой, если в каталоге игры есть файл, которого
    нет в его манифесте: требует обновление и вычищает каталог. Строку
    "Delegating to the entry point" он пишет, когда проверки позади и
    управление уходит движку; движок открывает stringtables примерно через
    100 мс. После выхода из игры убираем файлы, чтобы следующий запуск
    лаунчера снова прошёл чисто.
    """
    import time
    import glob

    sources = {}
    for name in sorted(os.listdir(stage)):
        path = os.path.join(stage, name)
        # В stage лежит ещё подкаталог base/ с распакованным архивом
        if not name.endswith('_en.str') or not os.path.isfile(path):
            continue
        with open(path, 'rb') as fh:
            sources[name] = fh.read()

    plan = []
    for target in targets:
        for name, blob in sources.items():
            base = name[:-len('_en.str')]
            for suffix in suffixes:
                plan.append((os.path.join(target, base + suffix), blob))

    def newest_log():
        logs = glob.glob(os.path.join(logdir, '*.log'))
        return max(logs, key=os.path.getmtime) if logs else None

    def delegated(path):
        if not path:
            return False
        try:
            with open(path, 'rb') as fh:
                return b'Delegating to the entry point' in fh.read()
        except OSError:
            return False

    # apply.sh запоминает лог до подготовки строк; без него - текущий
    if 'HON_BASELINE_LOG' in os.environ:
        baseline = os.environ['HON_BASELINE_LOG'] or None
    else:
        baseline = newest_log()
    print('  ожидаю запуск игры (текущий лог: %s)'
          % (os.path.basename(baseline) if baseline else 'нет'))

    deadline = time.time() + timeout
    while time.time() < deadline:
        current = newest_log()
        if current and (not baseline or os.path.basename(current)
                        != os.path.basename(baseline)) and delegated(current):
            break
        time.sleep(0.02)
    else:
        print('  игра так и не запустилась, выхожу')
        return

    written = 0
    for path, blob in plan:
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as fh:
                fh.write(blob)
            written += 1
        except OSError:
            pass
    placed_at = time.time()
    print('  лаунчер передал управление движку - положено файлов: %d' % written)

    # Дальше файлы обязаны быть убраны при любом исходе: если они переживут
    # скрипт, следующий запуск лаунчера сочтёт установку битой и зациклится
    # на "требуется обновление"
    import signal

    def _stop(signum, frame):
        raise KeyboardInterrupt

    for sig in (signal.SIGTERM, signal.SIGHUP):
        try:
            signal.signal(sig, _stop)
        except (OSError, ValueError):
            pass

    # Без inotify не отличить "движок не читает диск" от "не успели положить"
    probes = []
    if probe:
        import subprocess
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              'probe.py')
        probes = [subprocess.Popen([sys.executable, script, t,
                                    str(placed_at), '90'])
                  for t in targets if os.path.isdir(t)]

    try:
        seen = False
        while time.time() < deadline + 7200:
            if game_running(pattern):
                seen = True
            elif seen:
                break
            time.sleep(1.0)

        for pr in probes:
            try:
                pr.wait(timeout=95)
            except Exception:
                pr.kill()
    except KeyboardInterrupt:
        print('  прервано')
    finally:
        for pr in probes:
            if pr.poll() is None:
                pr.kill()
        removed = 0
        for path, _ in plan:
            try:
                os.remove(path)
                removed += 1
            except OSError:
                pass
        for target in targets:
            try:
                os.rmdir(target)
            except OSError:
                pass
        print('  файлов убрано: %d' % removed)


if __name__ == '__main__':
    main()
