#!/usr/bin/env python3
"""Обновляет в витрине блоки «Версии» по релизам GitHub.

Берёт релизы репозитория через `gh`, для каждого приложения отбирает стабильные версии
по префиксу тега и переписывает:
  * на странице приложения — всё между <!-- versions --> и <!-- /versions -->;
  * в README.md — ячейку между <!-- v:<приложение> --> и <!-- /v -->.

Запуск из корня витрины: python3 -I tools/sync.py [--check]
С --check файлы не меняются, код выхода 1, если они разошлись с релизами.
"""
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO = "theKomix/gwm-apps"
ROOT = Path(__file__).resolve().parent.parent
# папка страницы -> префикс тега
APPS = {
    "dimmer": "dimmer-v",
    "tboxrules": "tboxrules-v",
    "comfort": "comfort-v",
}


def releases():
    out = subprocess.run(
        ["gh", "api", f"repos/{REPO}/releases", "--paginate"],
        check=True, capture_output=True, text=True,
    ).stdout
    # --paginate склеивает страницы подряд: [...][...]
    dec, pos, items = json.JSONDecoder(), 0, []
    while pos < len(out):
        chunk, end = dec.raw_decode(out, pos)
        items += chunk
        pos = end
        while pos < len(out) and out[pos].isspace():
            pos += 1
    return items


def version_key(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def notes(body):
    """Пункты списка под заголовком «### …» из описания релиза."""
    lines = (body or "").replace("\r\n", "\n").split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith("### ")) + 1
    except StopIteration:
        return []
    items = []
    for l in lines[start:]:
        if l.startswith("- "):
            items.append(l)
        elif l.startswith("  ") and items:
            items[-1] += "\n" + l
        elif l.strip():
            break
    return items


def apk(rel):
    return next((a for a in rel["assets"] if a["name"].endswith(".apk")), None)


def date(rel):
    return datetime.strptime(rel["published_at"][:10], "%Y-%m-%d").strftime("%d.%m.%Y")


def page_block(folder, prefix, rels):
    last = rels[0]
    v = last["tag_name"][len(prefix):]
    a = apk(last)
    parts = [
        f"Актуальная версия — **{v}** от {date(last)}: "
        f"[{a['name']}]({a['browser_download_url']}), "
        f"[описание релиза]({last['html_url']}).",
        "",
        *notes(last["body"]),
    ]
    if len(rels) > 1:
        parts += ["", "Предыдущие версии:", ""]
        for r in rels[1:]:
            rv = r["tag_name"][len(prefix):]
            ra = apk(r)
            parts += [
                "<details>",
                f"<summary>{rv} от {date(r)}</summary>",
                "",
                *notes(r["body"]),
                "",
                f"[{ra['name']}]({ra['browser_download_url']}), [описание релиза]({r['html_url']}).",
                "",
                "</details>",
                "",
            ]
        parts.pop()
    parts += [
        "",
        f"[Все версии и описания](https://github.com/{REPO}/releases?q={prefix.removesuffix('-v')})",
    ]
    return "\n".join(parts)


def replace(text, start, end, new):
    pat = re.compile(re.escape(start) + r".*?" + re.escape(end), re.S)
    if not pat.search(text):
        raise SystemExit(f"нет маркеров {start} … {end}")
    return pat.sub(lambda m: f"{start}\n{new}\n{end}" if "\n" in new else f"{start}{new}{end}", text, count=1)


def main():
    check = "--check" in sys.argv
    allr = [r for r in releases() if not r["draft"] and not r["prerelease"]]
    changed = []

    def write(path, text):
        if path.read_text() != text:
            changed.append(path.relative_to(ROOT))
            if not check:
                path.write_text(text)

    readme = ROOT / "README.md"
    rtext = readme.read_text()
    for folder, prefix in APPS.items():
        rels = sorted(
            (r for r in allr if r["tag_name"].startswith(prefix) and apk(r)),
            key=lambda r: version_key(r["tag_name"][len(prefix):]),
            reverse=True,
        )
        if not rels:
            raise SystemExit(f"{folder}: нет стабильных релизов")
        page = ROOT / folder / "README.md"
        write(page, replace(page.read_text(), "<!-- versions -->", "<!-- /versions -->", page_block(folder, prefix, rels)))
        v = rels[0]["tag_name"][len(prefix):]
        cell = f" [{v}]({rels[0]['html_url']}) "
        rtext = replace(rtext, f"<!-- v:{folder} -->", "<!-- /v -->", cell)
    write(readme, rtext)

    for p in changed:
        print(("разошёлся: " if check else "обновлён: ") + str(p))
    if check and changed:
        sys.exit(1)


if __name__ == "__main__":
    main()
