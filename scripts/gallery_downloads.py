#!/usr/bin/env python3
"""Zählt, wie oft Plugins aus der Galerie geladen wurden, und trägt es in index.json ein.

    python3 scripts/gallery_downloads.py --katalog katalog     # im Workflow nach build_gallery.py

Raw-Dateien auf dem Zweig `plugin-katalog` zählt GitHub nicht. Dateien eines Releases schon
(`download_count`). Darum liegt jede .bdrop zusätzlich im Release `plugin-galerie`
(Vorabversion ohne BarDrop.dmg: Der Updater der App beachtet nur Releases mit BarDrop.dmg, und
`releases/latest` übergeht Vorabversionen). Der Eintrag zeigt dann auf diese Datei, und
`downloads` ist die Summe über alle Versionen des Plugins. BarDrop zeigt die fünf
meistgeladenen auf der Startseite von Einstellungen → Plugins.

Braucht GITHUB_TOKEN (im Workflow vorhanden) und GITHUB_REPOSITORY (Standard zzuuuiii/BarDrop).
Ohne Netz oder Token bleibt index.json unverändert.
"""
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import publish_plugin  # noqa: E402  (index.json lesen und schreiben)

TAG = "plugin-galerie"
API = "https://api.github.com"
UPLOADS = "https://uploads.github.com"


def request(method, url, token, data=None, content_type="application/json"):
    headers = {"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
               "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "BarDrop-Galerie"}
    if data is not None:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as response:
        body = response.read()
        return json.loads(body) if body else None


def release(repo, token):
    """Release `plugin-galerie` holen oder anlegen (am Zweig plugin-katalog, nie an main)"""
    try:
        return request("GET", f"{API}/repos/{repo}/releases/tags/{TAG}", token)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    body = {"tag_name": TAG, "target_commitish": publish_plugin.BRANCH, "name": "Plugin-Galerie",
            "prerelease": True, "make_latest": "false",
            "body": "Plugin files for the BarDrop gallery. Not a BarDrop version."}
    return request("POST", f"{API}/repos/{repo}/releases", token, json.dumps(body).encode())


def assets(repo, token, release_id):
    found, page = [], 1
    while True:
        batch = request("GET", f"{API}/repos/{repo}/releases/{release_id}/assets?per_page=100&page={page}", token)
        found += batch
        if len(batch) < 100:
            return found
        page += 1


def version_of(name, pid):
    """`io.x.convert-1.2.0.bdrop` → `1.2.0` für pid `io.x.convert`; sonst None (andere ids
    mit gleichem Anfang, etwa `io.x.convert-pro-1.0.0.bdrop`)"""
    prefix = pid + "-"
    if not (name.startswith(prefix) and name.endswith(".bdrop")):
        return None
    version = name[len(prefix):-len(".bdrop")]
    return version if version[:1].isdigit() else None


def main():
    argv = sys.argv[1:]
    if len(argv) != 2 or argv[0] != "--katalog":
        print(__doc__)
        sys.exit(2)
    katalog = pathlib.Path(argv[1]).resolve()
    token = os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GITHUB_REPOSITORY", "zzuuuiii/BarDrop")
    if not token:
        print("::warning title=Downloads::kein GITHUB_TOKEN, Downloads nicht gezählt")
        return
    data = publish_plugin.load_index(katalog)
    try:
        rel = release(repo, token)
        present = {a["name"]: a for a in assets(repo, token, rel["id"])}
        for entry in data["plugins"]:
            pid = entry["id"]
            name = f"{pid}-{entry['version']}.bdrop"
            local = katalog / "plugins" / pid / name
            if not entry.get("removed") and local.is_file():
                asset = present.get(name)
                if asset and asset["size"] != local.stat().st_size:
                    # Gleiche Version, anderer Inhalt: neu hochladen (Prüfsumme gilt für die neue)
                    request("DELETE", f"{API}/repos/{repo}/releases/assets/{asset['id']}", token)
                    asset = None
                if not asset:
                    url = f"{UPLOADS}/repos/{repo}/releases/{rel['id']}/assets?name={urllib.parse.quote(name)}"
                    asset = request("POST", url, token, local.read_bytes(), "application/octet-stream")
                    present[name] = asset
                    print(f"{pid} {entry['version']}: hochgeladen")
                entry["url"] = asset["browser_download_url"]
            counts = [a.get("download_count", 0) for n, a in present.items() if version_of(n, pid)]
            if counts:
                entry["downloads"] = sum(counts)
    except (urllib.error.URLError, KeyError, ValueError) as error:
        print(f"::warning title=Downloads::nicht gezählt: {error}")
        return
    publish_plugin.save_index(katalog, data)
    for entry in sorted(data["plugins"], key=lambda e: -e.get("downloads", 0)):
        print(f"{entry['id']}: {entry.get('downloads', 0)} Downloads")


if __name__ == "__main__":
    main()
