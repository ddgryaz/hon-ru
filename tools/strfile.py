"""Формат .str: общий для linux/lib/honru.py и проверок в tools/.

Порт под Windows (windows/lib/common.ps1, Read-HonStr) повторяет этот разбор:
сборки строк на обеих системах обязаны совпадать побайтно.
"""


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
