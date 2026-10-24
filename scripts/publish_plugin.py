#!/usr/bin/env python3
"""Trägt ein Plugin in die Galerie von BarDrop ein (Zweig `plugin-katalog`).

    python3 scripts/publish_plugin.py MeinPlugin/                   # prüfen, packen, eintragen
    python3 scripts/publish_plugin.py MeinPlugin/ --category images # mit Kategorie
    python3 scripts/publish_plugin.py MeinPlugin/ --standard        # für alle automatisch
    python3 scripts/publish_plugin.py MeinPlugin/ --push            # danach gleich hochladen
    python3 scripts/publish_plugin.py --remove io.github.name.plugin  # zurückziehen
    python3 scripts/publish_plugin.py MeinPlugin/ --no-tool-size    # Programme nicht messen

Was passiert:
1. Das Plugin wird mit denselben Regeln geprüft wie in `check_plugin.py`. Bei einem Fehler
   bricht das Skript ab.
2. Die Version muss neuer sein als die im Katalog (sonst bekäme niemand das Update).
3. Das Plugin wird gepackt nach `plugins/<id>/<id>-<version>.bdrop` im Katalog; ältere
   Fassungen desselben Plugins werden dort entfernt.
4. In `index.json` entsteht oder ändert sich der Eintrag: Name, Beschreibung, Symbol, Autor,
   Webseite, Rechte und Programme kommen aus der manifest.json, dazu Adresse, Prüfsumme,
   Größe von Plugin und Programmen (die Programme werden dafür angefragt bzw. bei ZIP
   geladen), Kategorie und Datum. Was der Katalog schon wusste (Kategorie, `standard`), bleibt.

Der Katalog liegt als eigener Arbeitsordner `.katalog/` neben dem Projekt (ein Git-Worktree
des Zweigs `plugin-katalog`, wird beim ersten Mal angelegt). Ein Push dorthin baut **kein**
Release; die App liest die Galerie von dort (PluginManager.catalogURL).
"""
import datetime
import hashlib
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import check_plugin  # noqa: E402  (gleiche Prüfregeln wie beim Import)

BRANCH = "plugin-katalog"
RAW = "https://raw.githubusercontent.com/zzuuuiii/BarDrop/" + BRANCH + "/"
CATEGORIES = ["images", "links", "documents", "text", "media", "files", "other"]


def fail(text):
    print(f"Fehler: {text}")
    sys.exit(1)


def git(*args, cwd=ROOT, check=True):
    return subprocess.run(["git", *args], cwd=cwd, check=check, capture_output=True, text=True)


def catalog_dir(path):
    """Arbeitsordner des Katalogs; legt den Worktree beim ersten Mal an"""
    if path:
        folder = pathlib.Path(path).resolve()
        if not (folder / "index.json").is_file():
            fail(f"{folder} enthält keine index.json")
        return folder
    folder = ROOT / ".katalog"
    if (folder / "index.json").is_file():
        return folder
    git("fetch", "origin", BRANCH, check=False)
    has_remote = git("rev-parse", "--verify", f"origin/{BRANCH}", check=False).returncode == 0
    if has_remote:
        git("worktree", "add", "-B", BRANCH, str(folder), f"origin/{BRANCH}")
    else:
        fail(f"Der Zweig {BRANCH} fehlt auf GitHub. Er wird einmal angelegt, siehe docs/PLUGINS.md (Abschnitt Katalog).")
    return folder


def tool_size(tool):
    """Größe eines Programms, wie es auf dem Mac liegt (Bytes), oder None.
    Ohne Archiv: Content-Length der Datei. Mit `archive: zip`: Archiv laden und die Größe der
    ausgepackten Datei `executable` lesen. `{arch}`: die größere der beiden Fassungen."""
    import io
    import urllib.request
    import zipfile

    def fetch(url, head):
        req = urllib.request.Request(url, method="HEAD" if head else "GET",
                                     headers={"User-Agent": "BarDrop-publish"})
        return urllib.request.urlopen(req, timeout=60)

    sizes = []
    url = tool.get("url", "")
    for arch in (["aarch64", "x86_64"] if "{arch}" in url else [None]):
        u = url.replace("{arch}", arch) if arch else url
        try:
            if tool.get("archive") == "zip":
                with fetch(u, head=False) as r:
                    archive = zipfile.ZipFile(io.BytesIO(r.read()))
                sizes.append(archive.getinfo(tool.get("executable", "")).file_size)
            else:
                with fetch(u, head=True) as r:
                    length = r.headers.get("Content-Length")
                if length is None:
                    with fetch(u, head=False) as r:
                        length = len(r.read())
                sizes.append(int(length))
        except Exception as e:  # noqa: BLE001  (nur Anzeige: ohne Größe weiter)
            print(f"Hinweis: Größe von {tool.get('id')} ({u}) unbekannt: {e}")
            return None
    return max(sizes) if sizes else None


def version_key(v):
    """1.2.10 > 1.2.9; Vorabversionen (1.0.0-beta.2) vor der fertigen 1.0.0"""
    main, _, pre = str(v).partition("-")
    nums = [int(x) if x.isdigit() else 0 for x in main.split(".")]
    nums += [0] * (4 - len(nums))
    pre_key = (1, ()) if not pre else (0, tuple(int(x) if x.isdigit() else x for x in re.split(r"[.]", pre)))
    return (nums, pre_key)


def localized(value):
    if isinstance(value, str):
        return {"en": value}
    return value if isinstance(value, dict) else None


def check(folder):
    """Dieselben Prüfungen wie check_plugin.py; liefert die manifest.json"""
    root, files, tmp = check_plugin.load(folder)
    if not root:
        fail("Kein Plugin-Ordner")
    try:
        manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as e:
        fail(f"manifest.json: {e}")
    check_plugin.check_manifest(manifest, files)
    script = root / str(manifest.get("script", "main.js"))
    if script.is_file():
        try:
            check_plugin.check_script(script.read_bytes().decode("utf-8"), manifest)
        except UnicodeDecodeError:
            check_plugin.error("Das Skript ist nicht in UTF-8 gespeichert")
    for h in check_plugin.hints:
        print(f"Hinweis: {h}")
    if check_plugin.errors:
        for e in check_plugin.errors:
            print(f"Fehler: {e}")
        sys.exit(1)
    return root, manifest


def load_index(folder):
    data = json.loads((folder / "index.json").read_text(encoding="utf-8"))
    if data.get("schema") != 1 or not isinstance(data.get("plugins"), list):
        fail("index.json hat nicht das Format schema 1")
    return data


def save_index(folder, data):
    data["plugins"].sort(key=lambda e: e["id"])
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    (folder / "index.json").write_text(text, encoding="utf-8")


def publish(args, options):
    folder = pathlib.Path(args[0]).resolve()
    if not folder.is_dir():
        fail(f"{folder} ist kein Ordner")
    root, manifest = check(folder)
    katalog = catalog_dir(options.get("katalog"))
    data = load_index(katalog)
    pid, version = manifest["id"], str(manifest["version"])
    old = next((e for e in data["plugins"] if e["id"] == pid), None)
    if old and not options.get("force") and version_key(version) <= version_key(old["version"]):
        fail(f"Version {version} ist nicht neuer als {old['version']} im Katalog. Version in der manifest.json erhöhen.")

    category = options.get("category") or (old or {}).get("category")
    if category and category not in CATEGORIES:
        fail(f"Kategorie „{category}“ gibt es nicht; möglich: {', '.join(CATEGORIES)}")
    if not category:
        print("Hinweis: keine Kategorie (--category …); die Galerie zeigt das Plugin unter „Sonstiges“")

    target_dir = katalog / "plugins" / pid
    target_dir.mkdir(parents=True, exist_ok=True)
    name = f"{pid}-{version}.bdrop"
    target = target_dir / name
    check_plugin.pack(root, target)
    for stale in target_dir.glob("*.bdrop"):
        if stale.name != name:
            stale.unlink()
    digest = hashlib.sha256(target.read_bytes()).hexdigest()

    entry = {
        "id": pid,
        "version": version,
        "name": localized(manifest["name"]),
        "url": RAW + f"plugins/{pid}/{name}",
        "sha256": digest,
        # Größe der .bdrop-Datei in Bytes (nachgeladene Programme kommen dazu, siehe „tools“)
        "size": target.stat().st_size,
        "updated": datetime.date.today().isoformat(),
        # Seit wann in der Galerie: bleibt bei neuen Versionen gleich (BarDrop zeigt zwei Monate „neu“)
        "added": (old or {}).get("added") or (old or {}).get("updated") or datetime.date.today().isoformat(),
        "permissions": [p for p in manifest.get("permissions", []) if isinstance(p, str)],
        "tools": [t.get("name") or t.get("id") for t in manifest.get("tools", []) if isinstance(t, dict)],
    }
    for key in ("description",):
        if manifest.get(key):
            entry[key] = localized(manifest[key])
    for key in ("icon", "author", "homepage", "minAppVersion"):
        if manifest.get(key):
            entry[key] = manifest[key]
    if category:
        entry["category"] = category
    # Größe der Programme, wie sie auf dem Mac liegen: Die Galerie zeigt Plugin und Programme
    # getrennt („8 KB · Programm 61 MB“)
    tools = [t for t in manifest.get("tools", []) if isinstance(t, dict)]
    if tools and not options.get("no-tool-size"):
        sizes = [tool_size(t) for t in tools]
        if all(size is not None for size in sizes):
            entry["toolsSize"] = sum(sizes)
    standard = options.get("standard") or (old or {}).get("standard")
    if standard:
        entry["standard"] = True

    data["plugins"] = [e for e in data["plugins"] if e["id"] != pid] + [entry]
    save_index(katalog, data)
    print(f"Eingetragen: {pid} {version} → {target.relative_to(katalog)} (sha256 {digest[:12]}…)")
    finish(katalog, f"{pid} {version}", options)


def remove(pid, options):
    katalog = catalog_dir(options.get("katalog"))
    data = load_index(katalog)
    entry = next((e for e in data["plugins"] if e["id"] == pid), None)
    if not entry:
        fail(f"{pid} steht nicht im Katalog")
    # Zurückgezogen bleibt im Katalog stehen: Sonst wüssten installierte Fassungen nichts davon
    entry["removed"] = True
    save_index(katalog, data)
    print(f"Zurückgezogen: {pid} (BarDrop entfernt Standard-Plugins beim nächsten Abgleich; andere verschwinden aus der Galerie)")
    finish(katalog, f"{pid} zurückgezogen", options)


def finish(katalog, what, options):
    if options.get("push"):
        git("add", "-A", cwd=katalog)
        git("commit", "-m", f"Galerie: {what}", cwd=katalog)
        git("push", "origin", f"HEAD:{BRANCH}", cwd=katalog)
        print(f"Hochgeladen auf {BRANCH}. BarDrop zeigt es spätestens nach einem Tag, beim Öffnen der Plugin-Einstellungen nach einer Stunde.")
    else:
        print(f"Noch nicht hochgeladen. Prüfen und hochladen:\n  cd {katalog} && git add -A && git commit -m 'Galerie: {what}' && git push origin HEAD:{BRANCH}")


def main():
    argv = sys.argv[1:]
    options, args = {}, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--category", "--katalog", "--remove"):
            if i + 1 >= len(argv):
                fail(f"{a} braucht einen Wert")
            options[a[2:]] = argv[i + 1]
            i += 2
            continue
        if a in ("--standard", "--push", "--force", "--no-tool-size"):
            options[a[2:]] = True
        elif a.startswith("--"):
            fail(f"Unbekannte Option {a}")
        else:
            args.append(a)
        i += 1
    if options.get("remove"):
        return remove(options["remove"], options)
    if len(args) != 1:
        print(__doc__)
        sys.exit(2)
    publish(args, options)


if __name__ == "__main__":
    main()
