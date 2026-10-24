#!/usr/bin/env python3
"""Baut die Galerie von BarDrop aus den .bdrop-Dateien im Ordner `Plugins/` auf `main`.

    python3 scripts/build_gallery.py --katalog katalog                  # wie im Workflow
    python3 scripts/build_gallery.py --katalog .katalog --source Tests/x # anderer Quellordner
    python3 scripts/build_gallery.py --katalog katalog --no-tool-size   # Programme nicht messen

Läuft in .github/workflows/plugin-gallery.yml, sobald sich etwas in `Plugins/` ändert.
`--katalog` ist ein Arbeitsordner des Zweigs `plugin-katalog` (mit index.json).

Was passiert:
1. Jede `*.bdrop` in `Plugins/` (auch in Unterordnern) wird mit denselben Regeln geprüft wie
   in `check_plugin.py`. Fehlerhafte werden übersprungen und als Annotation gemeldet.
2. Liegt dieselbe id mehrfach dort, gilt die höchste `version`.
3. Die Datei wird unverändert nach `plugins/<id>/<id>-<version>.bdrop` im Katalog kopiert
   (ältere Fassungen dort werden entfernt), der Eintrag wird neu gebaut wie in
   `publish_plugin.py`. `standard` und `category` bleiben aus dem alten Eintrag; sonst kommt
   `category` aus einem freiwilligen Schlüssel `category` der manifest.json. `updated` ändert
   sich nur, wenn sich die Prüfsumme geändert hat.
4. Ein Plugin, das aus `Plugins/` kam und dort nicht mehr liegt, bleibt mit `"removed": true`
   stehen (ohne .bdrop), damit installierte Fassungen davon erfahren.
   Welche ids aus `Plugins/` kommen, steht in `from-main.json` im Katalog. Einträge, die mit
   `publish_plugin.py` entstanden sind, bleiben unverändert.

Exitcode 0: alles in Ordnung; 3: Galerie geschrieben, aber mindestens eine Datei übersprungen.
"""
import datetime
import hashlib
import json
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import check_plugin  # noqa: E402  (gleiche Prüfregeln wie beim Import)
import publish_plugin  # noqa: E402  (Eintrag, Versionen, Größe der Programme)

SOURCES = "from-main.json"
SKIPPED = 3


def escape(text, prop=False):
    """Text für Annotationen von GitHub Actions"""
    text = str(text).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return text.replace(":", "%3A").replace(",", "%2C") if prop else text


def annotate(kind, path, text):
    print(f"::{kind} file={escape(display(path), prop=True)}::{escape(text)}")


def display(path):
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def check(path):
    """Prüft eine .bdrop wie check_plugin.py; liefert (manifest, Fehlerliste)"""
    check_plugin.errors.clear()
    check_plugin.hints.clear()
    root, files, tmp = check_plugin.load(path)
    manifest = None
    try:
        if root:
            try:
                manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
                check_plugin.error(f"manifest.json ist kein gültiges JSON: {e}")
            else:
                check_plugin.check_manifest(manifest, files)
                script = root / str(manifest.get("script", "main.js")) if isinstance(manifest, dict) else None
                if script and script.is_file():
                    data = script.read_bytes()
                    if len(data) > check_plugin.MAX_SCRIPT:
                        check_plugin.error("Das Skript ist größer als 1 MB")
                    try:
                        check_plugin.check_script(data.decode("utf-8"), manifest)
                    except UnicodeDecodeError:
                        check_plugin.error("Das Skript ist nicht in UTF-8 gespeichert")
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    for h in check_plugin.hints:
        # Der Schlüssel category ist für die Galerie gedacht, BarDrop ignoriert ihn
        if "\"category\"" not in h:
            annotate("notice", path, f"Hinweis: {h}")
    return manifest, list(check_plugin.errors)


def collect(source):
    """Gültige Plugins im Quellordner: {id: (Pfad, manifest)}, höchste Version je id"""
    found, skipped = {}, 0
    paths = sorted(p for p in source.rglob("*.bdrop")
                   if p.is_file() and not any(part.startswith(".") for part in p.relative_to(source).parts))
    for path in paths:
        manifest, errors = check(path)
        if errors:
            skipped += 1
            annotate("error", path, "Übersprungen: " + "; ".join(errors))
            continue
        pid, version = manifest["id"], str(manifest["version"])
        if pid in found:
            other_path, other = found[pid]
            if publish_plugin.version_key(version) <= publish_plugin.version_key(other["version"]):
                annotate("warning", path, f"{pid} {version}: {display(other_path)} hat dieselbe oder eine höhere Version, diese Datei wird nicht verwendet")
                continue
            annotate("warning", other_path, f"{pid} {other['version']}: {display(path)} hat Version {version}, diese Datei wird nicht verwendet")
        found[pid] = (path, manifest)
    return found, skipped


def build_entry(path, manifest, old, katalog, measure):
    pid, version = manifest["id"], str(manifest["version"])
    target_dir = katalog / "plugins" / pid
    target_dir.mkdir(parents=True, exist_ok=True)
    name = f"{pid}-{version}.bdrop"
    target = target_dir / name
    # Unverändert kopieren: gleiche Datei, gleiche Prüfsumme
    shutil.copyfile(path, target)
    for stale in target_dir.iterdir():
        if stale.name != name:
            shutil.rmtree(stale) if stale.is_dir() else stale.unlink()
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    old = old or {}
    same = old.get("sha256") == digest

    entry = {
        "id": pid,
        "version": version,
        "name": publish_plugin.localized(manifest["name"]),
        "url": publish_plugin.RAW + f"plugins/{pid}/{name}",
        "sha256": digest,
        "size": target.stat().st_size,
        "updated": old["updated"] if same and old.get("updated") else datetime.datetime.now(datetime.timezone.utc).date().isoformat(),
        # Seit wann das Plugin in der Galerie steht: bleibt bei neuen Versionen gleich. BarDrop
        # zeigt es zwei Monate lang als neu (ältere Einträge übernehmen ihr Datum `updated`)
        "added": old.get("added") or old.get("updated") or datetime.datetime.now(datetime.timezone.utc).date().isoformat(),
        "permissions": [p for p in manifest.get("permissions", []) if isinstance(p, str)],
        "tools": [t.get("name") or t.get("id") for t in manifest.get("tools", []) if isinstance(t, dict)],
    }
    if manifest.get("description"):
        entry["description"] = publish_plugin.localized(manifest["description"])
    for key in ("icon", "author", "homepage", "minAppVersion"):
        if manifest.get(key):
            entry[key] = manifest[key]

    category = old.get("category")
    if not category and manifest.get("category") is not None:
        category = manifest["category"]
        if category not in publish_plugin.CATEGORIES:
            annotate("warning", path, f"Kategorie „{category}“ gibt es nicht; möglich: {', '.join(publish_plugin.CATEGORIES)}")
            category = None
    if category:
        entry["category"] = category

    tools = [t for t in manifest.get("tools", []) if isinstance(t, dict)]
    if tools and measure:
        sizes = [publish_plugin.tool_size(t) for t in tools]
        if all(size is not None for size in sizes):
            entry["toolsSize"] = sum(sizes)
        elif same and "toolsSize" in old:
            # Netz gerade nicht erreichbar: bekannten Wert der unveränderten Datei behalten
            entry["toolsSize"] = old["toolsSize"]
    elif tools and same and "toolsSize" in old:
        entry["toolsSize"] = old["toolsSize"]
    if old.get("standard"):
        entry["standard"] = True
    return entry


def main():
    argv = sys.argv[1:]
    options = {"source": str(ROOT / "Plugins")}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--katalog", "--source"):
            if i + 1 >= len(argv):
                publish_plugin.fail(f"{a} braucht einen Wert")
            options[a[2:]] = argv[i + 1]
            i += 2
            continue
        if a == "--no-tool-size":
            options["no-tool-size"] = True
        else:
            print(__doc__)
            sys.exit(2)
        i += 1
    if "katalog" not in options:
        print(__doc__)
        sys.exit(2)
    katalog = pathlib.Path(options["katalog"]).resolve()
    source = pathlib.Path(options["source"]).resolve()
    if not source.is_dir():
        publish_plugin.fail(f"{source} ist kein Ordner")
    if (katalog / "index.json").is_file():
        old_entries = {e["id"]: e for e in publish_plugin.load_index(katalog)["plugins"]}
    elif katalog.is_dir():
        old_entries = {}
    else:
        publish_plugin.fail(f"{katalog} ist kein Ordner")
    try:
        managed = set(json.loads((katalog / SOURCES).read_text(encoding="utf-8")).get("plugins", []))
    except (OSError, json.JSONDecodeError, AttributeError):
        managed = set()

    found, skipped = collect(source)
    entries, lines = {}, []
    for pid, (path, manifest) in sorted(found.items()):
        old = old_entries.get(pid)
        version = str(manifest["version"])
        if old and not old.get("removed") and publish_plugin.version_key(version) < publish_plugin.version_key(old["version"]):
            # Ältere Version würde niemand bekommen und die neuere verdrängen
            annotate("warning", path, f"{pid} {version} ist älter als {old['version']} in der Galerie; Eintrag bleibt")
            entries[pid] = old
            lines.append(f"{pid} {old['version']}: unverändert (Datei hat ältere Version {version})")
            continue
        entry = build_entry(path, manifest, old, katalog, not options.get("no-tool-size"))
        entries[pid] = entry
        if not old:
            state = "neu"
        elif old.get("removed"):
            state = "wieder aufgenommen"
        elif old.get("sha256") != entry["sha256"]:
            state = f"aktualisiert (vorher {old['version']})" if old.get("version") != entry["version"] else "geändert"
        else:
            state = "unverändert"
        lines.append(f"{pid} {entry['version']}: {state}")

    for pid, old in sorted(old_entries.items()):
        if pid in entries:
            continue
        if pid in managed:
            # Aus Plugins/ gelöscht: als zurückgezogen stehen lassen, Datei entfernen
            entry = dict(old)
            state = "zurückgezogen" if not old.get("removed") else "zurückgezogen (unverändert)"
            entry["removed"] = True
            shutil.rmtree(katalog / "plugins" / pid, ignore_errors=True)
        else:
            entry = old
            state = "nicht aus Plugins/, unverändert"
        entries[pid] = entry
        lines.append(f"{pid} {entry.get('version', '')}: {state}")

    publish_plugin.save_index(katalog, {"schema": 1, "plugins": list(entries.values())})
    managed_now = sorted(managed | set(found))
    (katalog / SOURCES).write_text(json.dumps({"plugins": managed_now}, ensure_ascii=False, indent=2) + "\n",
                                   encoding="utf-8")
    for line in sorted(lines):
        print(line)
    if not lines:
        print("Keine Plugins")
    if skipped:
        print(f"{skipped} Datei(en) übersprungen, siehe Fehler oben")
        sys.exit(SKIPPED)


if __name__ == "__main__":
    main()
