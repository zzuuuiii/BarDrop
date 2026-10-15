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

notes = (ROOT / ".github/RELEASE_NOTES.md").read_text(encoding="utf-8")
marker = "<!-- de -->"
if notes.count(marker) != 1:
    error(".github/RELEASE_NOTES.md", f"genau eine Marke {marker} nötig")
else:
    english, german = notes.split(marker)
    if not re.search(r"^\* ", english, re.M) or not re.search(r"^\* ", german, re.M):
        error(".github/RELEASE_NOTES.md", "englischer und deutscher Teil brauchen je mindestens einen Punkt")
    if UMLAUT.search(english):
        error(".github/RELEASE_NOTES.md", "Deutscher Text im englischen Teil")

for e in errors:
    print(f"::error::{e}")
if errors:
    sys.exit(1)
print(f"Prüfungen bestanden (Version {version})")
