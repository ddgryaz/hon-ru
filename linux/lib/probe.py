#!/usr/bin/env python3
"""Диагностика: читает ли движок stringtables с диска.

По тексту в игре не отличить "движок не смотрит в каталог" от "не успели
положить файлы", а atime не поможет - разделы обычно монтируются с noatime.
Вешаем inotify на каталог и печатаем каждое обращение с задержкой
относительно момента, когда файлы были положены.
"""
import ctypes
import ctypes.util
import os
import struct
import sys
import time

IN_ACCESS = 0x00000001
IN_OPEN = 0x00000020
IN_CLOSE_NOWRITE = 0x00000010
MASK = IN_ACCESS | IN_OPEN | IN_CLOSE_NOWRITE

NAMES = {IN_ACCESS: 'read', IN_OPEN: 'open', IN_CLOSE_NOWRITE: 'close'}


def main():
    target, placed_at, duration = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])

    libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
    fd = libc.inotify_init1(os.O_NONBLOCK)
    if fd < 0:
        sys.exit('inotify_init1 не удался')
    wd = libc.inotify_add_watch(fd, target.encode(), MASK)
    if wd < 0:
        sys.exit('не удалось следить за %s: %s'
                 % (target, os.strerror(ctypes.get_errno())))

    print('  probe: слежу за обращениями к %s' % target)
    hits = 0
    deadline = time.time() + duration
    while time.time() < deadline:
        try:
            data = os.read(fd, 8192)
        except BlockingIOError:
            time.sleep(0.01)
            continue
        except OSError:
            break

        offset = 0
        while offset + 16 <= len(data):
            _wd, mask, _cookie, length = struct.unpack_from('iIII', data, offset)
            offset += 16
            name = data[offset:offset + length].split(b'\0', 1)[0].decode(
                'utf-8', 'replace')
            offset += length
            kind = ' '.join(n for bit, n in NAMES.items() if mask & bit)
            print('  probe: %+.3fs  %-6s %s'
                  % (time.time() - placed_at, kind, name or '(каталог)'))
            hits += 1

    if hits:
        print('  probe: обращений к каталогу: %d - движок читает диск' % hits)
    else:
        print('  probe: обращений НЕТ - движок в этот каталог не заглядывал')
    os.close(fd)


if __name__ == '__main__':
    main()
