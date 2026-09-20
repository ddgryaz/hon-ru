#!/usr/bin/env python3
"""Проверка bundle/ против файлов игры.

Ловит то, на чём перевод ломается в игре: расхождение чисел с данными
способностей, незакрытые цветовые коды, переведённые имена, латиницу внутри
русских слов.

Буква "ё" здесь не проверяется: шрифты игры (hon_intl, hon_bold_intl,
hon_cond_intl) содержат её глиф, хотя апстрим когда-то вычистил все 923
вхождения как якобы неотображаемые.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from honru import parse_str, load_overrides, lookup

STEMS = ('entities', 'interface', 'client_messages', 'game_messages', 'bot_messages')
CYR = set('абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ')
LAT = set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ')


def tags(value):
    return (len(re.findall(r'\^[a-zA-Z0-9]', value)),
            len(re.findall(r'\^\*', value)))


def check(base_dir, bundle_dir, overrides):
    found = {}

    def add(kind, key, detail=''):
        found.setdefault(kind, []).append((key, detail))

    for stem in STEMS:
        base_file = os.path.join(base_dir, stem + '_en.str')
        ru_file = os.path.join(bundle_dir, stem + '_en.str')
        if not (os.path.exists(base_file) and os.path.exists(ru_file)):
            continue
        with open(base_file, 'rb') as fh:
            base = parse_str(fh.read())
        with open(ru_file, 'rb') as fh:
            ru = parse_str(fh.read())
        over = load_overrides(overrides, stem)
        low = {}
        for k, v in ru.items():
            if v:
                low.setdefault(k.lower(), v)

        for key, eng in base.items():
            if not eng:
                continue
            value = over.get(key) or lookup(key, ru, low)
            is_name = (key.split(':')[0].endswith('_name')
                       and key.startswith(('Ability_', 'Item_', 'State_',
                                           'Pet_', 'Hero_', 'Gadget_',
                                           'Npc_', 'Heropet_')))

            # Ключа может не быть в bundle - тогда строка берётся из архива
            # игры и остаётся английской, это не дефект
            if not value:
                continue

            if is_name and any(c in CYR for c in value):
                add('имена переведены (должны быть английскими)',
                    '%s:%s' % (stem, key), value[:40])
                continue

            num_en = set(re.findall(r'\{[^}]*\}', eng))
            num_ru = set(re.findall(r'\{[^}]*\}', value))
            if num_en and num_ru - num_en:
                add('числа не совпадают с игрой', '%s:%s' % (stem, key),
                    '%s -> %s' % (sorted(num_ru - num_en), sorted(num_en)))

            # Пропавший плейсхолдер хуже лишнего: вместо списка по уровням
            # в переводе остаётся вбитая константа, верная только на одном
            if num_en - num_ru and value != eng:
                add('перевод потерял числа из игры', '%s:%s' % (stem, key),
                    ', '.join(sorted(num_en - num_ru))[:50])

            ro, rc = tags(value)
            eo, ec = tags(eng)
            if ro != rc and eo == ec:
                add('цветовой код не закрыт', '%s:%s' % (stem, key),
                    'откр %d / закр %d' % (ro, rc))

            if '^n' in value and '^n' not in eng:
                add('^n вместо переноса строки', '%s:%s' % (stem, key))

            # Цветовой код - каретка плюс один символ: ^o, ^*, ^;, ^!b
            # (слот игрока), ^^ - экранированная каретка. Срезать \n надо
            # первым, иначе каретка съест у него бэкслеш
            clean = re.sub(r'\\n|\^\^|\^![a-zA-Z0-9]|\^[a-zA-Z0-9*;:#]', ' ', value)
            mixed = [w for w in re.findall(r'[A-Za-zА-Яа-яёЁ]+', clean)
                     if set(w) & CYR and set(w) & LAT]
            if mixed:
                add('латиница внутри русского слова', '%s:%s' % (stem, key),
                    ', '.join(mixed[:3]))

    return found


def main():
    base_dir, bundle_dir, overrides = sys.argv[1:4]
    limit = int(sys.argv[4]) if len(sys.argv) > 4 else 5
    found = check(base_dir, bundle_dir, overrides)

    if not found:
        print('Проверки пройдены, замечаний нет.')
        return 0

    total = 0
    for kind in sorted(found, key=lambda k: -len(found[k])):
        rows = found[kind]
        total += len(rows)
        print('%s: %d' % (kind, len(rows)))
        for key, detail in rows[:limit]:
            print('   %-58s %s' % (key[:58], detail[:50]))
        if len(rows) > limit:
            print('   ... ещё %d' % (len(rows) - limit))
        print()
    print('всего замечаний: %d' % total)
    return 1


if __name__ == '__main__':
    sys.exit(main())
