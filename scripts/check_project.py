#!/usr/bin/env python3
"""Schnelle Prüfungen ohne Mac: Texte, Version, Release-Notizen.

Läuft in GitHub Actions vor den Tests. Jeder Fund wird als Fehler ausgegeben
und lässt den Build scheitern.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
errors = []


def error(where, text):
    errors.append(f"{where}: {text}")


# L("English", "Deutsch"), auch über mehrere Zeilen
STRING = r'"((?:[^"\\]|\\.)*)"'
L_CALL = re.compile(r'\bL\(\s*' + STRING + r'\s*,\s*' + STRING + r'\s*\)', re.S)
MENU_ITEM = re.compile(r'ClosureMenuItem\(\s*' + STRING)
UMLAUT = re.compile(r'[äöüÄÖÜß]')

for path in sorted((ROOT / "Sources").rglob("*.swift")):
    text = path.read_text(encoding="utf-8")
    rel = path.relative_to(ROOT)

    def line_of(match):
        return text.count("\n", 0, match.start()) + 1

    for m in L_CALL.finditer(text):
        english, german = m.group(1), m.group(2)
        where = f"{rel}:{line_of(m)}"
        if not english.strip() or not german.strip():
            error(where, "leerer Text in L(…)")
        if UMLAUT.search(english):
            error(where, f"Deutscher Text im englischen Teil: {english!r}")
        for part in (english, german):
            # Keine Auslassungspunkte in Menüs und Knöpfen
            if "…" in part or "..." in part:
                error(where, f"Auslassungspunkte: {part!r}")

    for m in MENU_ITEM.finditer(text):
        title = m.group(1)
        if "…" in title or "..." in title:
            error(f"{rel}:{line_of(m)}", f"Auslassungspunkte im Menü: {title!r}")

# Version, Änderungsprotokoll und Release-Notizen passen zusammen
version = (ROOT / "Resources/VERSION").read_text(encoding="utf-8").strip()
if not re.fullmatch(r"\d+\.\d+\.\d+(-beta\.\d+)?", version):
    error("Resources/VERSION", f"keine Version: {version!r}")

changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
top = re.search(r"^## (\S+)", changelog, re.M)
if not top or top.group(1) != version:
    error("CHANGELOG.md", f"oberster Eintrag ist {top.group(1) if top else 'keiner'}, VERSION ist {version}")

# Release-Notizen nur englisch (ab 1.31.0 Beta 12, docs/CHANGELOG-STYLE.md)
notes = (ROOT / ".github/RELEASE_NOTES.md").read_text(encoding="utf-8")
if "<!-- de -->" in notes:
    error(".github/RELEASE_NOTES.md", "nur englisch, keine Marke <!-- de --> mehr")
if not re.search(r"^\* \*\*", notes, re.M):
    error(".github/RELEASE_NOTES.md", "mindestens ein Punkt im Format * **Titel.** Text")
if UMLAUT.search(notes):
    error(".github/RELEASE_NOTES.md", "Deutscher Text in den Release-Notizen")

# BarDrop hat keine eingebauten Plugins: keine Namen bestimmter Dienste oder Programme,
# für die es Plugins gibt (auch nicht als Beispiel)
FOREIGN = re.compile(r"youtube|youtu\.be|yt-dlp|\bdeno\b|ffmpeg", re.I)
for pattern in ("Sources/**/*.swift", "Tests/**/*", "docs/*.md", "scripts/*.py", "Plugins/**/*",
                "README.md", "CHANGELOG.md", ".github/RELEASE_NOTES.md", "Resources/*"):
    for path in sorted(ROOT.glob(pattern)):
        if not path.is_file() or path.name == "check_project.py":
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if FOREIGN.search(line):
                error(f"{path.relative_to(ROOT)}:{number}", "Name eines Dienstes oder Programms für ein Plugin")

for e in errors:
    print(f"::error::{e}")
if errors:
    sys.exit(1)
print(f"Prüfungen bestanden (Version {version})")
