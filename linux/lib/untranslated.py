#!/usr/bin/env python3
"""Отчёт о непереведённых строках: что осталось на английском после мержа.

Сравнивает базу из resources0.jz с bundle/ и overrides.str. Ключ считается
непереведённым, если значение совпадает с английским или отсутствует.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from honru import parse_str, load_overrides, lookup


SERVICE = ('_search_terms', '_shop_categories', '_keywords')


def strip_markup(text):
    return re.sub(r'\^[a-zA-Z0-9*;:#!]|\\n|\{[^}]*\}', ' ', text)


def is_name(key):
    """Имена героев, способностей, предметов и состояний по правилу проекта
    остаются английскими - это не пробел в переводе."""
    head = key.split(':')[0]
    return head.endswith('_name')


def group_of(key):
    """Категория ключа - чтобы понимать, где именно дыры."""
    if is_name(key):
        return 'имена (остаются английскими)'
    if ':OnlyMidMap' in key:
        return 'Mid Wars (режим)'
    if key.startswith('report_'):
        return 'жалобы на игроков'
    if key.startswith('mm_'):
        return 'подбор игр и новый аккаунт'
    if key.startswith('rolepick'):
        return 'выбор роли'
    if key.startswith(('store', 'vanity', 'mstore')):
        return 'магазин и облик'
    if key.startswith('options_'):
        return 'настройки'
    if key.startswith('hero_tip'):
        return 'подсказки по героям'
    if key.startswith('Item_'):
        return 'предметы'
    if key.startswith('Ability_'):
        return 'способности'
    if key.startswith(('State_', 'Pet_', 'Gadget_', 'Npc_', 'Hero_')):
        return 'состояния, петы, юниты'
    return 'прочее'


def main():
    base_dir, bundle_dir, overrides = sys.argv[1], sys.argv[2], sys.argv[3]
    detail = sys.argv[4] if len(sys.argv) > 4 else ''

    groups = {}
    same_as_english = []
    total_keys = total_left = 0

    for stem in ('entities', 'interface', 'client_messages',
                 'game_messages', 'bot_messages'):
        base_file = os.path.join(base_dir, stem + '_en.str')
        ru_file = os.path.join(bundle_dir, stem + '_en.str')
        if not (os.path.exists(base_file) and os.path.exists(ru_file)):
            continue

        with open(base_file, 'rb') as fh:
            base = parse_str(fh.read())
        with open(ru_file, 'rb') as fh:
            ru = parse_str(fh.read())
        over = load_overrides(overrides, stem)
        ru_lower = {}
        for k, v in ru.items():
            if v:
                ru_lower.setdefault(k.lower(), v)

        for key, english in base.items():
            # Пустые в самой игре ключи переводить нечего: HoN держит текст
            # предметов в *_description_simple, а *_description часто пуст
            if not english:
                continue
            total_keys += 1
            value = over.get(key) or lookup(key, ru, ru_lower)
            if value:
                # Значение, дословно равное английскому, отчёт о пробелах
                # раньше не видел: ключ есть, а перевода нет. Служебные
                # ключи и строки без слов не в счёт - там нечего переводить
                if (value == english and not is_name(key)
                        and not key.endswith(SERVICE)):
                    if len(re.findall(r'[A-Za-z]{2,}', strip_markup(english))) >= 3:
                        same_as_english.append((stem, key, english))
                continue
            total_left += 1
            groups.setdefault(group_of(key), []).append((stem, key, english))

    names = len(groups.get('имена (остаются английскими)', []))
    real = total_left - names
    print('Всего ключей в игре: %d, без перевода: %d (%.1f%%)'
          % (total_keys, total_left, 100.0 * total_left / max(total_keys, 1)))
    print('Из них требуют перевода: %d, остальное - имена' % real)
    if same_as_english:
        print('Плюс %d строк, где перевод дословно равен английскому'
              % len(same_as_english))
    print()
    for name in sorted(groups, key=lambda g: (g.startswith('имена'),
                                              -len(groups[g]))):
        rows = groups[name]
        print('%-32s %5d' % (name, len(rows)))

    if not detail:
        print()
        print('Подробнее: make untranslated GROUP=предметы')
        return

    print()
    matched = [r for g, rows in groups.items() if detail.lower() in g.lower()
               for r in rows]
    if not matched:
        print('Нет группы "%s"' % detail)
        return
    for stem, key, english in matched:
        print('%s:%s' % (stem, key))
        print('    %s' % re.sub(r'\s+', ' ', english)[:150])


if __name__ == '__main__':
    main()
