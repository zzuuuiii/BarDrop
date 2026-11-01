#!/usr/bin/env python3
"""Prüft ein BarDrop-Plugin nach denselben Regeln wie BarDrop beim Import, und packt es.

    python3 scripts/check_plugin.py MeinPlugin/            # Ordner prüfen
    python3 scripts/check_plugin.py MeinPlugin/ --pack     # prüfen und MeinPlugin.bdrop erzeugen
    python3 scripts/check_plugin.py MeinPlugin.bdrop       # fertige Datei prüfen

Fehler (Exitcode 1) lehnt BarDrop ab oder führen dazu, dass das Plugin nie läuft. Hinweise
sind Dinge, die BarDrop annimmt, die aber fast immer ein Versehen sind. Ist Node.js
installiert, wird auch die Syntax des Skripts geprüft, und zwar wie BarDrop es lädt: als
normales Skript, nicht als Modul (kein `import`/`export`, kein `await` und kein `return`
außerhalb von Funktionen).

Link-Muster prüft BarDrop mit der Regex-Sprache von macOS (ICU), nicht mit der von Python.
Unterschiede, die BarDrop ablehnt (`(?P<name>…)`, `{,3}`), meldet dieses Programm als Fehler;
ICU-Schreibweisen wie `(?<name>…)` und `\\k<name>` nimmt es an.

Diese Regeln müssen mit Sources/BarDrop/Plugins/PluginManifest.swift und
PluginPackage.swift übereinstimmen. Wer dort etwas ändert, ändert es auch hier und in
docs/PLUGINS.md.
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

MAX_PACKAGE = 5 * 1024 * 1024
MAX_UNPACKED = 20 * 1024 * 1024
MAX_SCRIPT = 1024 * 1024
# Beschreibung höchstens so lang, je Sprache (wie PluginManifest.maxDescriptionLength): Sie steht
# in der Galerie, auf bardrop.app und im Fenster vor dem Installieren und soll dort kurz bleiben
MAX_DESCRIPTION = 100
ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$")
VERSION_PATTERN = re.compile(r"^\d+(\.\d+){0,2}$")
PERMISSIONS = {"network", "run", "clipboard"}
TRIGGERS = {"menu", "action", "automatic"}
SETTING_TYPES = {"toggle", "choice", "text"}
KNOWN_KEYS = {"schema", "id", "name", "description", "version", "author", "homepage", "icon", "actionTitle",
              "minAppVersion", "script", "match", "triggers", "automaticByDefault", "defaults", "permissions", "tools",
              "settings", "canReplaceOriginal", "batch", "consent", "installs"}
API = {"writeFile", "createLink", "readFile", "progress", "notify", "isCancelled", "sleep", "log", "fetch",
       "download", "run", "setClipboard", "settings", "language", "appVersion", "outputDirectory",
       "pluginDirectory", "plugin", "readData", "writeData", "findProgram"}

# Keine Downloader in der Galerie: Programme, die Videos oder Musik von Plattformen laden, und
# Beschreibungen, die genau das versprechen (oft gegen deren Nutzungsbedingungen oder das
# Urheberrecht). Gilt für neue Plugins und Versionen; was schon so in der Galerie steht, bekommt
# einen Hinweis (wie bei der Länge der Beschreibung)
# Die Namen stehen zerlegt da: check_project.py lässt Namen solcher Dienste und Programme sonst
# nirgends im Repository zu (BarDrop hat und bewirbt keine solchen Plugins)
DOWNLOADER_PROGRAMS = re.compile(
    r"(?<![\w-])(" r"yt" r"-dlp|yt" r"_dlp|you" r"tube-dl|you" r"tube_dl|gallery-dl|spotdl|you-get|streamrip|deemix|savify|n_m3u8dl\w*|lux"
    r")(?![\w-])", re.I)
PLATFORMS = re.compile(r"you" r"tube|you" r"tu\.be|tiktok|instagram|spotify|apple music|soundcloud|deezer|netflix|twitch|vimeo", re.I)
DOWNLOAD_WORDS = re.compile(r"\bdownload|herunterl|\blädt\b|\blaedt\b|\brip(s|ped|pt)?\b", re.I)
DOWNLOADER_RULE = ("Downloader für Inhalte von Plattformen (Videos, Musik) sind in der Galerie nicht erlaubt: "
                   "Sie verstoßen oft gegen deren Nutzungsbedingungen oder das Urheberrecht")

errors, hints = [], []


def error(text):
    errors.append(text)


def hint(text):
    hints.append(text)


def localized(value, where, required=False):
    if value is None:
        if required:
            error(f"{where} fehlt")
        return
    if isinstance(value, str):
        if required and not value.strip():
            error(f"{where} ist leer")
        return
    if not isinstance(value, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in value.items()):
        error(f"{where} muss ein Text oder {{\"en\": \"…\", \"de\": \"…\"}} sein")
        return
    if "en" not in value:
        hint(f"{where} hat kein \"en\": für Englisch nimmt BarDrop dann irgendeine andere Sprache")
    if "de" not in value:
        hint(f"{where} hat kein \"de\": auf Deutsch erscheint der englische Text")
    if required and not (value.get("en") or next(iter(sorted(value.items())), ("", ""))[1]).strip():
        error(f"{where} ist leer")


def string_list(value, where):
    """Liste von Texten oder nichts. BarDrop lehnt alles andere beim Lesen des Manifests ab."""
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        error(f"{where} muss eine Liste von Texten sein, z. B. [\"…\"]")
        return [v for v in value if isinstance(v, str)] if isinstance(value, list) else []
    return value


def check_pattern(p):
    """Link-Muster wie NSRegularExpression (ICU) prüfen, so gut es ohne macOS geht."""
    if not isinstance(p, str):
        return error(f"Ungültiger regulärer Ausdruck in \"links.patterns\": {p!r}")
    if re.search(r"\(\?P[<=>]", p):
        return error(f"Link-Muster {p!r}: (?P<…>) ist Python-Schreibweise, BarDrop kennt nur (?<name>…)")
    if re.search(r"(?<!\\)\{,\d*\}", p):
        return error(f"Link-Muster {p!r}: {{,n}} kennt BarDrop nicht, {{0,n}} schreiben")
    # ICU-Schreibweise für benannte Gruppen in Pythons übersetzen, sonst gleich prüfen
    python = re.sub(r"\(\?<(?![=!])([A-Za-z][A-Za-z0-9]*)>", r"(?P<\1>", p)
    python = re.sub(r"\\k<([A-Za-z][A-Za-z0-9]*)>", r"(?P=\1)", python)
    try:
        re.compile(python)
    except re.error as e:
        error(f"Ungültiger regulärer Ausdruck in \"links.patterns\": {p!r} ({e})")


def without_comments(text):
    """Skript ohne Kommentare (Texte in Anführungszeichen bleiben), damit Wörter in
    Kommentaren keine Fehler auslösen."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in "\"'`":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


INSTALL_BLOCKED = {".ssh", ".gnupg", ".Trash", ".aws", ".kube", ".docker", ".config/gh", ".password-store"}


def install_path_allowed(path):
    """Wie PluginManifest.installPaths in BarDrop: nur, was ein Plugin selbst anlegt"""
    if not path.startswith("~/"):
        return False
    parts = path[2:].split("/")
    if not parts or any(p in ("", ".", "..") for p in parts):
        return False
    if parts[0] == "Library":
        return len(parts) >= 3 and parts[1] in ("Application Support", "Caches") \
            and parts[2] not in ("BarDrop", "com.zzuuuiii.bardrop")
    return parts[0].startswith(".") and len(parts) >= 2 \
        and parts[0] not in INSTALL_BLOCKED and "/".join(parts[:2]) not in INSTALL_BLOCKED


def long_descriptions(value):
    """Sprachen, deren Beschreibung länger als MAX_DESCRIPTION ist: [(Sprache, Länge)]"""
    texts = {"en": value} if isinstance(value, str) else value if isinstance(value, dict) else {}
    return [(k, len(v.strip())) for k, v in sorted(texts.items()) if isinstance(v, str) and len(v.strip()) > MAX_DESCRIPTION]


def check_manifest(m, files, published=False):
    """`published`: Diese Version steht schon so in der Galerie (eine zu lange Beschreibung ist
    dann nur ein Hinweis, die Grenze gilt ab der nächsten Version)"""
    if not isinstance(m, dict):
        return error("manifest.json muss ein JSON-Objekt sein")
    for key in m:
        if key not in KNOWN_KEYS:
            hint(f"Unbekannter Schlüssel \"{key}\" wird ignoriert (Tippfehler?)")
    if m.get("schema", 1) != 1:
        error("\"schema\" muss 1 sein")
    pid = m.get("id")
    if not isinstance(pid, str) or not ID_PATTERN.match(pid) or len(pid) > 120:
        error("\"id\" fehlt oder ist ungültig (z. B. io.github.name.plugin, nur Buchstaben, Ziffern, - und Punkte, höchstens 120 Zeichen)")
    localized(m.get("name"), "\"name\"", required=True)
    for key in ("description", "actionTitle", "consent"):
        localized(m.get(key), f"\"{key}\"")
    report = hint if published else error
    tool_text = " ".join(str(t.get(k, "")) for t in (m.get("tools") or []) if isinstance(t, dict) for k in ("id", "name", "url"))
    if DOWNLOADER_PROGRAMS.search(tool_text):
        report(DOWNLOADER_RULE + " (Programm in \"tools\")")
    descriptions = m.get("description") if isinstance(m.get("description"), dict) else {"": m.get("description") or ""}
    for text in descriptions.values():
        if isinstance(text, str) and PLATFORMS.search(text) and DOWNLOAD_WORDS.search(text):
            report(DOWNLOADER_RULE + " (laut Beschreibung)")
            break
    for lang, length in long_descriptions(m.get("description")):
        (hint if published else error)(
            f"\"description\" ({lang}) hat {length} Zeichen, erlaubt sind höchstens {MAX_DESCRIPTION}: "
            "ein, zwei kurze Sätze, was das Plugin tut (Einzelheiten gehören in die Einstellungen oder auf die Homepage)")
    version = m.get("version")
    if not isinstance(version, str) or not VERSION_PATTERN.match(version):
        error("\"version\" fehlt oder ist ungültig (1, 1.2 oder 1.2.3, als Text)")
    minimum = m.get("minAppVersion")
    if minimum is not None and not isinstance(minimum, str):
        error("\"minAppVersion\" muss ein Text sein (z. B. \"1.31.0\")")
    elif minimum is not None and not VERSION_PATTERN.match(minimum):
        if VERSION_PATTERN.match(minimum.split("-")[0]):
            hint(f"\"minAppVersion\" \"{minimum}\": BarDrop vergleicht nur \"{minimum.split('-')[0]}\", besser so schreiben")
        else:
            error("\"minAppVersion\" ist ungültig (z. B. \"1.31.0\")")
    elif minimum is None:
        hint("\"minAppVersion\" fehlt: setze mindestens \"1.31.0\"")

    icon = m.get("icon")
    if icon is None:
        hint("\"icon\" fehlt: das Plugin bekommt ein graues Puzzleteil")
    elif not isinstance(icon, dict) or not isinstance(icon.get("symbol"), str):
        error("\"icon\" braucht \"symbol\" (Name eines SF Symbols)")
    elif "color" in icon and not re.fullmatch(r"#?[0-9A-Fa-f]{6}", str(icon["color"])):
        hint("\"icon.color\" ist kein #RRGGBB: die Kachel wird grau")

    script = m.get("script", "main.js")
    if not isinstance(script, str) or "/" in script or script.startswith(".") or not script.endswith(".js"):
        error("\"script\" muss ein Dateiname auf .js ohne Ordner sein")
    elif script not in files:
        error(f"Skript \"{script}\" fehlt im Plugin")

    match = m.get("match")
    if not isinstance(match, dict):
        error("\"match\" fehlt")
        match = {}
    types = string_list(match.get("types"), "\"match.types\"")
    exts = string_list(match.get("extensions"), "\"match.extensions\"")
    links = match.get("links") or {}
    if not isinstance(links, dict):
        error("\"match.links\" muss ein Objekt mit \"hosts\" und/oder \"patterns\" sein")
        links = {}
    hosts = string_list(links.get("hosts"), "\"links.hosts\"")
    patterns = string_list(links.get("patterns"), "\"links.patterns\"")
    if not (types or exts or hosts or patterns):
        error("\"match\" braucht mindestens eine Regel (types, extensions, links.hosts oder links.patterns)")
    for ext in exts:
        if not isinstance(ext, str) or not ext.strip("."):
            error(f"Ungültige Endung in \"extensions\": {ext!r}")
        elif ext.startswith("."):
            hint(f"Endung \"{ext}\" ohne Punkt schreiben (wird toleriert)")
    for t in types:
        if not isinstance(t, str) or "." not in t:
            error(f"\"types\" erwartet Uniform Type Identifier wie public.image, nicht {t!r}")
    for h in hosts:
        if "/" in h or ":" in h:
            error(f"\"links.hosts\" erwartet nur Domains wie example.com, nicht {h!r}")
        elif h.strip() != "*" and "*" in (h.strip()[2:] if h.strip().startswith("*.") else h):
            error(f"\"links.hosts\": {h!r} geht nicht; \"*\" steht allein (alle Links) oder als \"*.example.com\"")
        elif h.strip().startswith("*."):
            hint(f"\"links.hosts\": {h!r} ist dasselbe wie \"{h.strip()[2:]}\" (Unterdomains passen immer)")
    for p in patterns:
        check_pattern(p)

    if "triggers" in m:
        triggers = string_list(m.get("triggers"), "\"triggers\"")
        unknown = [t for t in triggers if t not in TRIGGERS]
        if not [t for t in triggers if t in TRIGGERS]:
            error("\"triggers\" nennt keinen bekannten Auslöser (menu, action, automatic): "
                  "BarDrop lehnt das Plugin ab. Ohne \"triggers\" gelten alle drei")
        elif unknown:
            hint(f"Unbekannte \"triggers\" werden ignoriert: {unknown}")
    permissions = string_list(m.get("permissions"), "\"permissions\"")
    for p in permissions:
        if p not in PERMISSIONS:
            error(f"Unbekanntes Recht \"{p}\" (erlaubt: network, run, clipboard): BarDrop lehnt das Plugin ab")
    tools = m.get("tools") or []
    if not isinstance(tools, list):
        error("\"tools\" muss eine Liste sein")
        tools = []
    seen_tools = set()
    for tool in tools:
        tid = tool.get("id") if isinstance(tool, dict) else None
        if not isinstance(tid, str) or not isinstance(tool.get("name"), str) or not isinstance(tool.get("url"), str):
            error("Jedes Programm in \"tools\" braucht \"id\", \"name\" und \"url\" (als Text)")
            continue
        if tid in seen_tools:
            error(f"Programm \"{tid}\" steht zweimal in \"tools\"")
        seen_tools.add(tid)
        for key in ("sha256", "checksums", "homepage", "license", "archive", "executable"):
            if key in tool and not isinstance(tool[key], str):
                error(f"Programm \"{tid}\": \"{key}\" muss ein Text sein")
                tool = {k: v for k, v in tool.items() if k != key}
        if "arch" in tool and tool["arch"] not in ("arm64", "x86_64"):
            error(f"Programm \"{tid}\": \"arch\" muss \"arm64\" oder \"x86_64\" sein")
        if "refreshDays" in tool and (not isinstance(tool["refreshDays"], int) or isinstance(tool["refreshDays"], bool)):
            error(f"Programm \"{tid}\": \"refreshDays\" muss eine ganze Zahl sein")
        if not tool["url"].startswith("https://"):
            error(f"Programm \"{tid}\": \"url\" muss mit https:// beginnen")
        if "checksums" in tool and not str(tool["checksums"]).startswith("https://"):
            error(f"Programm \"{tid}\": \"checksums\" muss mit https:// beginnen")
        if not tool.get("sha256") and not tool.get("checksums"):
            error(f"Programm \"{tid}\": \"sha256\" oder \"checksums\" fehlt")
        if tool.get("sha256") and not re.fullmatch(r"[0-9A-Fa-f]{64}", tool["sha256"]):
            error(f"Programm \"{tid}\": \"sha256\" muss 64 Hex-Zeichen haben")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tid):
            error(f"Programm \"{tid}\": \"id\" darf nur Buchstaben, Ziffern, Punkt, - und _ enthalten")
        archive = tool.get("archive")
        if archive is not None:
            exe = tool.get("executable")
            if archive != "zip":
                error(f"Programm \"{tid}\": \"archive\" kennt nur \"zip\"")
            if not isinstance(exe, str) or not exe or exe.startswith("/") or ".." in exe.split("/"):
                error(f"Programm \"{tid}\": mit \"archive\" braucht es \"executable\" (Pfad im Archiv, z. B. \"tool\")")
        elif tool["url"].lower().endswith((".zip", ".tar.gz", ".tgz", ".dmg", ".pkg")):
            error(f"Programm \"{tid}\": Archive nur mit \"archive\": \"zip\" und \"executable\"; tar, DMG und PKG gehen nicht")
        if "{arch}" in tool["url"] and tool.get("sha256"):
            error(f"Programm \"{tid}\": mit {{arch}} gibt es je Mac eine andere Datei, also \"checksums\" statt \"sha256\"")
        if "run" not in permissions:
            error(f"Programm \"{tid}\" lässt sich nur mit dem Recht \"run\" starten")
    for flag in ("automaticByDefault", "canReplaceOriginal", "batch"):
        if flag in m and not isinstance(m[flag], bool):
            error(f"\"{flag}\" muss true oder false sein")
    if m.get("batch") and m.get("canReplaceOriginal"):
        hint("\"canReplaceOriginal\" wirkt nicht zusammen mit \"batch\": Bei mehreren Objekten gibt es kein einzelnes Original")
    if m.get("automaticByDefault") and (({"network", "run"} & set(permissions)) or tools):
        hint("\"automaticByDefault\" gilt nicht für Plugins mit network, run oder tools: der Nutzer schaltet es selbst ein")
    installs = m.get("installs")
    if installs is not None:
        if not isinstance(installs, list) or not all(isinstance(p, str) for p in installs):
            error("\"installs\" muss eine Liste von Pfaden sein, z. B. [\"~/.local/share/mytool\"]")
        else:
            for path in installs:
                if not install_path_allowed(path):
                    hint(f"\"installs\": {path} wird ignoriert (nur ~/.<Ordner>/<Name> oder "
                         "~/Library/Application Support/<Name> bzw. ~/Library/Caches/<Name>)")
    defaults = m.get("defaults")
    if defaults is not None:
        if not isinstance(defaults, dict):
            error("\"defaults\" muss ein Objekt sein")
        else:
            for key, value in defaults.items():
                if key not in ("actionBar", "automatic", "replaceOriginal"):
                    hint(f"Unbekannter Schlüssel in \"defaults\" wird ignoriert: {key}")
                elif not isinstance(value, bool):
                    error(f"\"defaults.{key}\" muss true oder false sein")
            trig = m.get("triggers") or ["menu", "action", "automatic"]
            if defaults.get("actionBar") and "action" not in trig:
                hint("\"defaults.actionBar\" wirkt nur mit dem Auslöser \"action\"")
            if defaults.get("automatic") and "automatic" not in trig:
                hint("\"defaults.automatic\" wirkt nur mit dem Auslöser \"automatic\"")
            if defaults.get("replaceOriginal") and not m.get("canReplaceOriginal"):
                hint("\"defaults.replaceOriginal\" wirkt nur mit \"canReplaceOriginal\": true")

    seen_keys = set()
    for spec in m.get("settings") or []:
        key = spec.get("key") if isinstance(spec, dict) else None
        if not isinstance(key, str) or spec.get("type") not in SETTING_TYPES:
            error("Jede Einstellung braucht \"key\" und \"type\" (toggle, choice oder text)")
            continue
        if key in seen_keys:
            error(f"Einstellung \"{key}\" steht zweimal in \"settings\"")
        seen_keys.add(key)
        localized(spec.get("title"), f"Einstellung \"{key}\": \"title\"", required=True)
        if key == "replaceOriginal":
            error("Der Schlüssel \"replaceOriginal\" ist für BarDrop reserviert")
        if spec["type"] == "choice":
            options = spec.get("options") or []
            if not options:
                error(f"Einstellung \"{key}\": \"choice\" braucht \"options\"")
            values = [o.get("value") for o in options if isinstance(o, dict)]
            if any(not isinstance(v, str) for v in values):
                error(f"Einstellung \"{key}\": jeder \"value\" muss ein Text sein (auch Zahlen in Anführungszeichen)")
            if "default" in spec and spec["default"] not in values:
                error(f"Einstellung \"{key}\": \"default\" ist keine der Möglichkeiten")
        if spec["type"] == "toggle" and "default" in spec and not isinstance(spec["default"], bool):
            error(f"Einstellung \"{key}\": \"default\" muss true oder false sein")


def check_script(full_text, m, published=False):
    text = without_comments(full_text)
    found = sorted({x.lower() for x in DOWNLOADER_PROGRAMS.findall(text)} - {"lux"})
    if found:
        (hint if published else error)(DOWNLOADER_RULE + f" (Skript nutzt {', '.join(found)})")
    if not re.search(r"\bfunction\s+run\b|\b(var|let|const)\s+run\s*=|(^|[^.\w])run\s*=", text):
        error("Das Skript definiert keine Funktion run(item)")
    for name in sorted(set(re.findall(r"\bbardrop\.(\w+)", text))):
        if name not in API:
            error(f"bardrop.{name} gibt es nicht")
    # setTimeout, URL, TextEncoder & Co. stellt BarDrop selbst bereit (PluginPrelude)
    for word, why in (("require(", "es gibt keine Module"), ("document.", "es gibt kein DOM"),
                      ("XMLHttpRequest", "bardrop.fetch verwenden"), ("window.", "es gibt kein window")):
        if word in text:
            error(f"\"{word.rstrip('(.')}\" gibt es in BarDrop-Plugins nicht: {why}")
    if re.search(r"bardrop\.run\(\s*[\"'](/usr/bin/)?which[\"']", text):
        hint("Programme mit bardrop.findProgram(name) suchen statt which zu starten: findet auch Programme im Benutzerordner und solche, die andere Plugins geladen haben")
    if re.search(r"Tipp:|Tip:|\\n\\nHint", full_text):
        hint("Einen Tipp zum Fehler als hint mitgeben (throw { message, hint }) statt an die Meldung zu hängen: BarDrop zeigt ihn abgesetzt")
    if re.search(r"(^|[^.\w])fetch\(", text):
        error("Globales fetch gibt es nicht: bardrop.fetch verwenden")
    if re.search(r"\b(let|const|class)\s+console\b", text):
        error("console ist schon vorhanden; nicht mit let/const neu anlegen")
    perms = set(m.get("permissions") or [])
    for call, perm in (("fetch", "network"), ("download", "network"), ("run", "run"), ("setClipboard", "clipboard")):
        if re.search(rf"\bbardrop\.{call}\(", text) and perm not in perms:
            error(f"bardrop.{call} braucht das Recht \"{perm}\" in \"permissions\"")
    for perm in perms:
        calls = {"network": ("fetch", "download"), "run": ("run",), "clipboard": ("setClipboard",)}[perm] if perm in PERMISSIONS else ()
        if calls and not any(f"bardrop.{c}(" in text for c in calls):
            hint(f"Recht \"{perm}\" wird im Skript nicht verwendet: weglassen, dann steht es nicht in den Fenstern und der Galerie")
    node = shutil.which("node")
    if node:
        # Als normales Skript übersetzen (wie JSContext.evaluateScript), nicht ausführen.
        # `node --check` prüfte als Modul und ließ import, export, await und return oben durch.
        compile_only = ("const fs = require('fs'), vm = require('vm');"
                        "try { new vm.Script(fs.readFileSync(process.argv[1], 'utf8'), {filename: 'main.js'}); }"
                        "catch (e) { console.error(e.stack ? e.stack.split('\\n').slice(0, 5).join('\\n') : String(e));"
                        " process.exit(1); }")
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "main.js"
            path.write_text(full_text, encoding="utf-8")
            r = subprocess.run([node, "-e", compile_only, str(path)], capture_output=True, text=True)
        if r.returncode != 0:
            error("Syntaxfehler im Skript (BarDrop lädt es als normales Skript, nicht als Modul):\n"
                  + r.stderr.strip())
    else:
        hint("Node.js nicht gefunden: Syntax des Skripts nicht geprüft")


def load(path):
    """Liefert (Ordner mit manifest.json, Dateinamen dort, temporärer Ordner oder None)."""
    if path.is_dir():
        root = path
        tmp = None
    else:
        if path.stat().st_size > MAX_PACKAGE:
            error("Die .bdrop-Datei ist größer als 5 MB")
        tmp = pathlib.Path(tempfile.mkdtemp())
        try:
            with zipfile.ZipFile(path) as z:
                # Erst die ausgepackte Größe, dann entpacken (eine kleine Datei kann Gigabytes ergeben)
                unpacked = sum(i.file_size for i in z.infolist())
                if unpacked > MAX_UNPACKED:
                    error(f"Ausgepackt wäre das Plugin {unpacked / 1e6:.0f} MB groß, höchstens 20 MB")
                    return None, set(), tmp
                z.extractall(tmp)
        except zipfile.BadZipFile:
            error("Die Datei ist kein ZIP-Archiv")
            return None, set(), tmp
        root = tmp
        if not (root / "manifest.json").exists():
            inner = [p for p in root.iterdir() if not p.name.startswith(".") and p.name != "__MACOSX"]
            if len(inner) == 1 and (inner[0] / "manifest.json").exists():
                root = inner[0]
    if not (root / "manifest.json").exists():
        error("manifest.json fehlt (direkt im Archiv oder in genau einem Ordner darin)")
        return None, set(), tmp
    files = {p.name for p in root.iterdir() if p.is_file()}
    return root, files, tmp


def pack(folder, target):
    total = 0
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(folder.rglob("*")):
            relative = p.relative_to(folder)
            # Versteckte Dateien und Ordner (.git, .DS_Store …) gehören nicht ins Plugin
            if any(part.startswith(".") or part == "__MACOSX" for part in relative.parts):
                continue
            if p.is_file() and not p.is_symlink():
                z.write(p, relative.as_posix())
                total += p.stat().st_size
    if target.stat().st_size > MAX_PACKAGE:
        error("Die erzeugte .bdrop-Datei ist größer als 5 MB")
    if total > MAX_UNPACKED:
        error("Das Plugin ist ausgepackt größer als 20 MB")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        print(__doc__)
        sys.exit(2)
    path = pathlib.Path(args[0]).resolve()
    root, files, tmp = load(path)
    manifest = {}
    if root:
        try:
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            error(f"manifest.json ist kein gültiges JSON: {e}")
        else:
            check_manifest(manifest, files)
            script = root / str(manifest.get("script", "main.js"))
            if script.is_file():
                data = script.read_bytes()
                if len(data) > MAX_SCRIPT:
                    error("Das Skript ist größer als 1 MB")
                try:
                    check_script(data.decode("utf-8"), manifest)
                except UnicodeDecodeError:
                    error("Das Skript ist nicht in UTF-8 gespeichert")
            for link in root.rglob("*"):
                if link.is_symlink():
                    hint(f"Verweis {link.name} wird beim Import entfernt")
    if "--pack" in sys.argv and root and path.is_dir() and not errors:
        target = path.parent / (path.name + ".bdrop")
        pack(root, target)
        print(f"Gepackt: {target}")
    if tmp:
        shutil.rmtree(tmp, ignore_errors=True)
    for h in hints:
        print(f"Hinweis: {h}")
    for e in errors:
        print(f"Fehler: {e}")
    if errors:
        sys.exit(1)
    print(f"In Ordnung: {manifest.get('id', path.name)} {manifest.get('version', '')}")


if __name__ == "__main__":
    main()
