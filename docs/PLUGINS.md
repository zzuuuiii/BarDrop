# BarDrop plugins: exact reference

English · [Deutsch](PLUGINS.de.md)

This file describes BarDrop’s plugin system completely and exactly as the code implements it (as of 1.31.0 Beta 5). What isn’t written here doesn’t exist. Anyone writing a plugin follows this file and checks the result with `scripts/check_plugin.py` (section 11).

Source: `Sources/BarDrop/Plugins/`. When something changes there, this file, its German version and `scripts/check_plugin.py` are updated in the same commit.

---

## 1. Overview

* A plugin is **one file with the extension `.bdrop`**: a ZIP archive with `manifest.json` and a JavaScript script.
* BarDrop **doesn’t come with any plugin**. Plugins are off until the user turns on “Use plugins” in Settings → Plugins, and each plugin is then off on its own.
* A plugin gets **one item of the shelf** (file, folder or link). Everything it writes to its **output folder** becomes **new items right next to the original**.
* A plugin is started in three ways: **right-click**, **action bar** or **automatically when dropped**.
* The script runs in **JavaScriptCore** and sees only the object `bardrop`. Internet, programs and the clipboard need **permissions**, which BarDrop asks for before the first run, in **one** window (when importing, “Install” already counts as allowing; plugins from the gallery get them right away).

## 2. The .bdrop file

| Rule | Value |
| --- | --- |
| Format | ZIP archive, extension `.bdrop` |
| Size | at most 5 MB (5,242,880 bytes), at most 20 MB unpacked |
| Layout | `manifest.json` at the top of the archive **or** in exactly one folder inside it (hidden entries and `__MACOSX` don’t count) |
| Script | the file named by `script` in the manifest; at most 1 MB; UTF-8 |
| Other files | allowed (texts, templates); the script reads them with `bardrop.readFile(bardrop.pluginDirectory + "/template.txt")`. The import dialog lists them, and they are part of the fingerprint (6). |
| Symbolic links | deleted when unpacking |

BarDrop unpacks with `/usr/bin/ditto`. An installed plugin lives in `~/Library/Application Support/BarDrop/Plugins/<id>/`; the folder name must equal the `id`.

**Making one:** `python3 scripts/check_plugin.py MyPlugin/ --pack` checks the folder and writes `MyPlugin.bdrop`. By hand: `ditto -c -k --norsrc --noextattr MyPlugin MyPlugin.bdrop`, or “Compress” in the Finder and rename `.zip` to `.bdrop`.

**Installing:** double-click the file, or Settings → Plugins → Advanced → “Import”. BarDrop shows the name, permissions, programs to load and the script, with a note that the plugin isn’t from the catalog. Nothing is installed before “Install”. If a plugin with the same `id` exists, the button says “Update”. A standard plugin from the catalog can’t be replaced by an import. After importing, BarDrop turns on “Use plugins” and the new plugin, set up according to `defaults` (3.1). An update leaves on/off and the settings as they are. If an installed plugin can no longer be read (for example after editing it), it appears in the list with the error, with “Show in Finder” and, except for standard plugins, “Remove”.

## 3. manifest.json

Unknown keys are ignored. A key with the wrong type (for example a number instead of text) makes the whole manifest unreadable.

### 3.1 All keys

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `schema` | number | no | Must be `1`. Missing means 1. |
| `id` | text | yes | Unique identifier, e.g. `io.github.name.my-plugin`. Pattern `^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$`: at least one dot, only letters, digits and hyphens; at most 120 characters. Stays the same across updates. |
| `name` | text (3.2) | yes | Name in Settings and dialogs. The English text must not be empty. |
| `description` | text (3.2) | no | Shown at the top of the plugin’s page, in the gallery and as the action’s help text. |
| `version` | text | yes | `1`, `1.2` or `1.2.3`, as text in quotes. Pattern `^\d+(\.\d+){0,2}$`. No beta suffix. |
| `author` | text | no | Shown next to the version. |
| `homepage` | text | no | Stored, not shown at the moment. |
| `icon` | object | no | `{"symbol": "…", "color": "#RRGGBB"}`, see 3.4. |
| `actionTitle` | text (3.2) | no | Title in the right-click menu and the action bar. Defaults to `name`. |
| `minAppVersion` | text | no | Oldest BarDrop version, e.g. `"1.31.0"`. Compared without the beta suffix: 1.31.0 Beta 2 counts as 1.31.0. An older BarDrop rejects the plugin. Recommended: always set it. |
| `script` | text | no | File name of the script, default `"main.js"`. Must end in `.js`, contain no `/` and not start with `.`. |
| `match` | object | yes | What the plugin handles, see 4. |
| `triggers` | list | no | Subset of `"menu"`, `"action"`, `"automatic"`. Missing means all three. Unknown values are skipped. If no known value is left (also with `[]`), BarDrop rejects the plugin. |
| `automaticByDefault` | boolean | no | Older key, prefer `defaults.automatic`. “Automatically when dropped” is on even without installing and allowing (standard plugins from the catalog), but **only** when `triggers` allows `automatic` and the plugin has neither `network` nor `run` nor `tools`. |
| `permissions` | list | no | Subset of `"network"`, `"run"`, `"clipboard"`, see 6. An **unknown** value rejects the whole plugin. |
| `tools` | list | no | Programs BarDrop loads, see 7. Requires the `run` permission. |
| `settings` | list | no | The plugin’s settings, see 3.3. |
| `canReplaceOriginal` | boolean | no | Shows a “Replace original” switch (off by default), see 8. Has no effect together with `batch`. |
| `batch` | boolean | no | With several items, run **once** with all of them instead of once per item: `run(item, items)`, see 9.2. The result appears next to the first item. Also for items dropped together with “Automatically when dropped”. |
| `consent` | text (3.2) | no | A note the user has to agree to **once** before the plugin can be turned on or run. If an update changes the text, BarDrop asks again. |
| `defaults` | object | no | How the plugin is set up after installing: `actionBar` (added to the action bar if there is room; only with the `action` trigger), `automatic` (“Automatically when dropped”; only with `automatic`), `replaceOriginal` (“Replace original”; only with `canReplaceOriginal`), each `true` or `false`. Applies after “Install” (import) or after “Get” (gallery), also for plugins with `network`, `run` or `tools`, because the plugin then has all its access. After that only the user changes anything; updates leave the settings alone. The plugin’s own settings (`settings`) have their default in `default`, see 3.3. |

### 3.2 Text in two languages

Wherever “text (3.2)” appears, there are two forms:

```json
"name": "Used for both languages"
"name": { "en": "English text", "de": "Deutscher Text" }
```

Rule: in German, `de` is used, otherwise `en`. If the wanted language is missing, `en` is used. If `en` is missing too, the alphabetically first entry is used. Other language keys aren’t used.

### 3.3 settings

```json
"settings": [
  { "key": "format", "type": "choice", "title": { "en": "Format", "de": "Format" },
    "info": { "en": "Shown behind the (i)", "de": "Erscheint hinter dem (i)" },
    "default": "png",
    "options": [ { "value": "png", "title": "PNG" }, { "value": "jpg", "title": "JPEG" } ] },
  { "key": "keepName", "type": "toggle", "title": { "en": "Keep name", "de": "Namen behalten" }, "default": true },
  { "key": "prefix", "type": "text", "title": { "en": "Prefix", "de": "Präfix" }, "default": "" }
]
```

| Key | Required | Meaning |
| --- | --- | --- |
| `key` | yes | Name of the value in `bardrop.settings`. `replaceOriginal` is reserved. |
| `type` | yes | `toggle` (switch), `choice` (picker), `text` (text field). |
| `title` | yes | Text (3.2). |
| `info` | no | Text (3.2), shown behind an (i). |
| `default` | no | `toggle`: `true`/`false` (default `false`). `choice`: one of the `value`s (default: the first option). `text`: text (default empty). |
| `options` | for `choice` | List of `{"value": "text", "title": text (3.2)}`. `value` is **always text**, also for numbers (`"1080"`, not `1080`). |

They look like the rest of BarDrop’s Settings: two options, or three short ones, appear as a segmented control in the row, anything else as a menu.

In the script: `bardrop.settings.<key>` gives `true`/`false`, or text. `bardrop.settings.replaceOriginal` tells whether “Replace original” is on.

### 3.4 icon

* `symbol`: name of an **SF Symbol**, the system symbols the Shortcuts app uses, present on every Mac (e.g. `arrow.down.circle.fill`, `photo`, `link`, `doc.text`). Apple’s “SF Symbols” app lists the names. A name the Mac doesn’t know shows a puzzle piece.
* `color`: tile color as `#RRGGBB` (the `#` may be left out). Invalid or missing: gray.

BarDrop always draws the symbol **white on the colored tile with a slight gradient**, like the icons in its Settings; 16 pt in the right-click menu, in the action bar in the style of the Share action. Custom image files as icons don’t exist.

## 4. match: what a plugin handles

```json
"match": {
  "types": ["public.image", "com.adobe.pdf"],
  "extensions": ["txt", "md"],
  "links": { "hosts": ["example.com"], "patterns": ["^https://example\\.com/watch\\?"] }
}
```

At least **one** of the four lists needs entries. An item matches if **any** rule matches.

**What BarDrop knows about an item:**

| Item in the shelf | `kind` | Type | Extension |
| --- | --- | --- | --- |
| `.webloc` file with a readable address (`URL` in the property list) | `link` | `com.apple.web-internet-location` | `webloc` |
| Folder (not a package) | `folder` | `public.folder` | the folder’s, usually empty |
| Anything else, including packages like `.app` | `file` | from the extension, otherwise from the file | the extension, lowercased |

BarDrop always stores links itself as `.webloc`.

**Rules:**

* `extensions`: case-insensitive; leading dots are removed (`".PNG"` = `png`).
* `types`: Uniform Type Identifiers. An item also matches if its type **conforms** to it: `public.image` matches PNG, JPEG, HEIC …, `public.movie` matches MP4 and MOV, `public.text` matches TXT, Markdown and source code. Unknown identifiers are skipped.
* `links.hosts`: **links only**. `example.com` matches `example.com` and every subdomain (`www.example.com`, `m.example.com`), but not `notexample.com`. `*.example.com` means the same as `example.com`. `*` on its own matches every `http` or `https` link; anywhere else `*` isn’t allowed. Only the domain: no `https://`, no path, no port.
* `links.patterns`: **links only**. Regular expressions (macOS ICU syntax) on the whole address, **case-insensitive**; a match anywhere is enough. Anchor with `^`. Double every `\` in JSON.
* A link also matches `extensions: ["webloc"]`.

**Links from the browser:** when a link is dragged together with a preview image (e.g. from a web page), BarDrop normally keeps the image. If the link matches `links` of a **turned-on** plugin, BarDrop keeps the link as `.webloc` instead. This only applies to `links.hosts` and `links.patterns`, and not to rules that accept any address (host `*` or a pattern matching any page): those get links you drag, but an image stays an image.

## 5. Triggers

**Right-click (`menu`):** matching, turned-on plugins appear below the usual entries after a separator, with their icon and `actionTitle`. Up to three directly, from four on in a “Plugins” submenu. With several items selected, a plugin appears if it matches at least one; it then runs once for every matching item, or once with all of them with `batch`.

**Action bar (`action`):** Settings → Actions → “Add Action” (or `defaults.actionBar`, 3.1). While the plugin is off, its action is neither in the shelf nor in Settings → Actions and doesn’t count toward the bar’s limit; turning the plugin on puts it back at the end if there is room. Drag onto it: runs for the dragged items; a click doesn’t run it. If nothing matches, BarDrop beeps.

**Automatically when dropped (`automatic`):** a switch per plugin, off by default (exception: `automaticByDefault`, 3.1). Only what the user puts into the shelf counts: dragging and ⌘V. Not: screenshots, results of actions and plugins, undo, the introduction. For each dropped item **at most one** plugin runs: the first in the order under Settings → Plugins → Advanced → “Order when dropped” that is turned on, runs automatically and matches. Drag plugins there to change the order (shown from two automatic plugins on). Where the shelf usually shows the number of items, it then shows “Plugin running”.

A plugin only starts if it can run **without asking**: consent given (`consent`), all `permissions` granted, all `tools` allowed. If something is missing, BarDrop asks for all of it **before the start, in one window**: when turning the plugin on, when turning on “Automatically when dropped”, for right-click and action bar, and when dropping (once per drop). If you decline, it doesn’t run, and the shelf shows “Not started”. During an automatic run, a plugin never asks.

**At the same time:** at most three plugins run at once; more wait in the order they were started (their placeholder shows a clock and “Waiting”). The same plugin doesn’t start a second time for the same file while it is still running; the shelf then shows “Already running”.

## 6. Permissions

| Permission | allows | Line in the window |
| --- | --- | --- |
| `network` | `bardrop.fetch`, `bardrop.download` | “Internet access” |
| `run` | `bardrop.run`, and so `tools` | “Run programs”, as a warning: full access to the Mac |
| `clipboard` | `bardrop.setClipboard` | “Clipboard” (counts as granted without asking, like in macOS) |

* A call without the permission in `permissions` fails **immediately** with `Permission “…” is missing in manifest.json`, without asking.
* Everything is allowed **at once**: consent, permissions and programs share one window (“Allow “…”?” with one line per permission and program, “Allow” and “Cancel”). It appears when turning a plugin on or before the first run, never during a run. “Cancel” doesn’t start the plugin and asks again next time.
* When importing a `.bdrop` file, permissions, programs and the notice are already listed in the install window: “Install” or “Update” grants them, and no further window follows.
* Plugins from the gallery (“Get”, standard plugins and automatic updates from the catalog, each downloaded with a checksum check) get consent, permissions and programs right away, without an allow window.
* `clipboard` always counts as granted once it is listed in `permissions` (putting text on the clipboard isn’t asked for by macOS either).
* Granted permissions apply to **exactly this code**: a SHA-256 over **all files** of the plugin (path and content; only `.DS_Store` doesn’t count), because the script can read other files and run them as code. Any change to any file on disk resets all permissions, and BarDrop asks again before the next run. Updates from the catalog grant everything the new version declares, without asking; an import grants the permissions in its list.
* A plugin without permission is off: the list shows “Off”, and turning it on first asks in one window for everything missing (for example after an edited script lost its permissions). Info → “Access” on the plugin’s page shows the state in one row (“Allowed” or “Not allowed”) with “Allow” or “Revoke”, and below lists permissions, programs and notice separately, each “Allowed” or “Not allowed”. “Revoke” takes back permissions, programs and consent, which turns the plugin off. Plugins from the gallery need no permission: if it is missing, BarDrop downloads the checked version again at the next sync.
* There is **no macOS sandbox** around plugins. Without permissions, the script can only use the calls in 9. A program started with `run`, however, has the user’s full rights.

## 7. tools: programs loaded on demand

BarDrop never ships third-party programs. A plugin can name programs that BarDrop loads on first use (downloading is allowed together with the permissions, see 6):

```json
"tools": [
  { "id": "mytool", "name": "My Tool",
    "url": "https://example.com/releases/1.0/mytool_macos",
    "sha256": "64 hex characters",
    "license": "MIT", "homepage": "https://example.com" }
]
```

| Key | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Name the script starts it by: `bardrop.run("mytool", […])`. Plugins share a program if its download address is the same (see below). |
| `name` | yes | Shown in the allow window. |
| `url` | yes | `https://`, pointing to **one single executable** for macOS. Archives (ZIP, DMG, PKG) are **not** unpacked. Redirects are followed. |
| `sha256` | one of both | Checksum of the file. |
| `checksums` | one of both | `https://` address of a checksum list from the publisher. BarDrop looks for the line `<64 hex characters> <file name>` or `<…> *<file name>`; the file name is the last part of `url`. For addresses pointing to “latest”. |
| `license` | no | Shown in the allow window. |
| `homepage` | no | Stored. |
| `refreshDays` | no | After this many days, BarDrop loads the file again on next use, without asking again. Without it: never. |
| `archive` | no | `"zip"`: `url` delivers a ZIP archive. BarDrop checks the checksum **of the archive**, unpacks it and keeps only the file `executable`. Other archive types don’t exist. |
| `executable` | with `archive` | Path of the program inside the archive, e.g. `"tool"` or `"bin/tool"`, without a leading `/` and without `..`. |

`{arch}` in `url` and `checksums` becomes the Mac’s architecture: `aarch64` (Apple chip) or `x86_64` (Intel). That means a different file per Mac, so use `checksums` instead of `sha256`. `id` may only contain letters, digits, `.`, `-` and `_`; the file is saved **under this name**, so other programs find it by this name (e.g. `id: "tool"`).

Example of a program inside an archive:

```json
{ "id": "tool", "name": "Tool",
  "url": "https://example.com/downloads/tool-{arch}.zip",
  "checksums": "https://example.com/downloads/tool-{arch}.zip.sha256",
  "archive": "zip", "executable": "tool", "license": "MIT", "refreshDays": 30 }
```

Sequence: if the file is missing, BarDrop asks (“Download …?” with origin and license). If several things are missing when you turn on “Automatically when dropped” or when you drop something (consent, permissions, programs), BarDrop asks for all of them in **one** window. After “Download” it downloads (the placeholder shows “Downloading …” with percent), compares the checksum (on a mismatch the file is deleted and the call fails), makes the file executable (755) and removes the quarantine flag. Location: `~/Library/Application Support/BarDrop/Tools/<id>-<address tag>/<id>` with `meta.json` next to it, so two plugins with the same `id` but different addresses don’t overwrite each other. The permission is stored per plugin **for exactly this address** and then also applies to automatic runs. If an update changes the address, BarDrop asks again; an update from the catalog allows the new address right away. Only an outdated program from the same address (`refreshDays`, new checksum) is downloaded again without asking. If two runs need it at the same time, only one downloads, the other waits. If another plugin has already loaded the same file (same address, and with `sha256` the same checksum, still within `refreshDays`), it is shared, also under a different `id`: nothing is downloaded, the user is still asked once for this plugin (unless it comes from the gallery). Settings → Plugins → plugin → Info → Programs → “Update” downloads the plugin’s allowed programs again, without asking, for example when a newer version of the program fixes an error. Removing a plugin keeps loaded programs.

## 8. Result

* `run(item)` ends without an error (also an `async` `run` whose promise resolves): **success**. The return value isn’t used.
* `run` throws or its promise is rejected: **failure**. Nothing is added. BarDrop shows **no window**: the placeholder shakes briefly, the shelf shows “Failed”, and the message appears in Settings under “Last error” and in the log: `error.message`, for errors in the code (`TypeError`, `ReferenceError`, `SyntaxError` …) with the type in front and file and line after it (`TypeError: … (main.js:12)`); a message of the plugin’s own, thrown with `throw new Error(…)`, appears exactly as it is; a tip for the user goes into `hint` (`throw { message: "…", hint: "Install … and try again." }`, or `error.hint = "…"` on an `Error`), at most 300 characters, shown below the message and in its own log line, so don’t append it to the message. “Last error” stays until quitting.
* On success, all **top-level entries** of the output folder are taken, sorted by name, **folders included**. Excluded are names starting with `.` and the extensions `part`, `ytdl`, `tmp`, `download`, `crdownload`. If the folder is empty, only the placeholder disappears.
* The files are moved into BarDrop’s storage and inserted **right after the original** (in the order the user sees; in a stack, after the original inside the stack). They appear immediately with their preview and are selected. If the original is no longer in the shelf, they are added like newly dropped items.
* “Replace original” (only with `canReplaceOriginal`, the user’s switch, decided when the run starts): while the plugin runs, its placeholder stands **in the original’s place** and the original itself isn’t shown. Afterwards the result appears exactly there, without a fade; the original is taken **out of the shelf**, never deleted, and ⌘Z brings it back. If the run fails or is canceled, the original is shown again.

**Placeholder:** while a plugin runs (from 0.3 s after the start, so a run that ends at once doesn’t flash), a preview stands next to the original (with “Replace original”, in its place), with the plugin’s name below it (or the `label` from `bardrop.progress`). It starts out see-through and becomes solid with the progress; a thin bar between the picture and the name fills with `bardrop.progress`. Without progress the picture gently becomes more solid and more see-through again, and a short light moves along the bar. At first it shows the file the plugin works on. As soon as a file appears in the output folder, the placeholder shows the icon of its kind (also while it is still being written; `film.mp4.part` counts as a video), and once it is finished (not hidden, none of the extensions above, not empty, the same size twice in a row, checked twice a second) its preview, so you see the result before the plugin is done. If the run fails, the placeholder shakes briefly and its bar turns red before it disappears. While plugins are running, the top right of the shelf’s header shows “Plugin running”, or “2 plugins running” for several. Placeholders can be selected like other items (click, ⌘- or ⇧-click, selection rectangle, arrow keys); `⌫` cancels the selected ones. When the pointer is over the placeholder, a click on the symbol in the middle pauses or resumes, and the x at the top right cancels. Right-click: progress in percent (updates while the menu is open), “Pause” or “Resume”, “Cancel”. A plugin that is still waiting only offers “Cancel”.

* **Pause:** started programs and every program they started themselves get `SIGSTOP`, downloads pause. The script itself and `bardrop.sleep` keep running.
* **Cancel:** takes effect at once: the placeholder disappears and the slot for the next plugin is free. Started programs and their child programs get `SIGTERM`, anything still running after 3 s gets `SIGKILL`. Requests are canceled, the result is discarded. The work folder is deleted only once all programs have ended. Programs the script started without `await` are ended the same way; after the end, none are started.
* **Turning off or removing** a plugin cancels its running and waiting jobs, and so does turning off all plugins.
* Quitting BarDrop cancels running plugins.

## 9. The script

### 9.1 Environment

* macOS’s JavaScriptCore: the JavaScript language with `async`/`await`, `Promise`, `JSON`, `RegExp`, `Map`, `Set` and so on.
* **Also available, provided by BarDrop:** `URL` and `URLSearchParams` (as in browsers), `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval`, `queueMicrotask`, `TextEncoder`/`TextDecoder` (UTF-8 only), `atob`/`btoa`. An error in a timer callback makes the run fail.
* **Not available:** DOM, `window`, global `fetch` (use `bardrop.fetch`), `XMLHttpRequest`, `require`, `import`, Node modules, `structuredClone`, file access other than through `bardrop`.
* `console.log`, `console.info`, `console.warn`, `console.error` exist; they write like `bardrop.log` to the plugin log. Don’t redeclare `console` with `let`/`const`.
* Every run has its **own, fresh context**: globals don’t survive a run. Only `settings` persist.
* The script is first evaluated once as a whole (global definitions), then `run(item, items)` is called. `items` is the list of all items of the run: with `batch` all of them, otherwise just `item`. `function run(item)` keeps working.
* An error during that first evaluation (e.g. a syntax error) is a failure. So is a missing `run` (“The script has no function run”).
* Long computations run as long as they need. Once a run ends (“Cancel”, “Stop” in Settings → Plugins, turning the plugin off), BarDrop also ends a script that is still computing, even in an endless loop, within about a quarter of a second. While a plugin has runs, the list in Settings → Plugins shows “Running”; the plugin’s page has “Stop” at the top.
* The script is loaded as a **classic script**, not a module: no `import`/`export`, no `await` and no `return` outside functions. `function run`, `var run =`, `let run =` and `const run =` all work.

### 9.2 item

| Field | Type | Content |
| --- | --- | --- |
| `kind` | text | `"file"`, `"folder"` or `"link"` |
| `path` | text | Path of the file in the shelf (for links the `.webloc`) |
| `name` | text | File name with extension; for links the name without `.webloc` |
| `extension` | text | Extension, lowercased, without dot |
| `type` | text | Uniform Type Identifier, `""` if unknown |
| `url` | text | links only: the address |
| `size` | number | Size in bytes, not for folders |

Every entry of `items` has the same fields.

### 9.3 bardrop

Every call used with `await` returns a promise.

| Call | Permission | Result and rules |
| --- | --- | --- |
| `bardrop.outputDirectory` | | Path of the output folder (text). The result goes here. |
| `bardrop.pluginDirectory` | | Path of the plugin’s own folder (text), with `manifest.json`, the script and other files. For `bardrop.readFile(bardrop.pluginDirectory + "/template.txt")`. |
| `bardrop.writeFile(name, text)` | | Writes `text` as UTF-8 to the output folder (other values become text as with `String()`, so objects become `[object Object]`: use `JSON.stringify` first). `name` must be text, `text` must not be `undefined` or `null`, otherwise error. Returns the path. The name is cleaned (9.4); if it exists, the file becomes `Name 2.txt` etc. |
| `bardrop.createLink(url, title)` | | Creates `<title>.webloc` in the output folder (without `title`: the domain). Only `http` and `https` addresses. Returns the path. Invalid address: error. |
| `bardrop.readFile(path)` | | Reads a file as text (UTF-8, invalid bytes replaced), at most 20 MB. A path that doesn’t start with `/` is relative to the output folder; for the plugin’s own files use `bardrop.pluginDirectory`. Allowed only: the paths of `item` and `items`, files in the output folder, files in the plugin’s own folder. Otherwise error. For binary data use `bardrop.readData`. |
| `bardrop.readData(path)` | | Like `readFile`, same rules and limit, but returns the bytes as a `Uint8Array`. |
| `bardrop.writeData(name, data)` | | Like `writeFile`, but writes bytes unchanged: `data` is a `Uint8Array` (or another typed array), an `ArrayBuffer`, a list of numbers 0–255 or Base64 text. Anything else: error. Returns the path. |
| `bardrop.progress(fraction, label)` | | `fraction` 0 to 1 (clamped); not a number (e.g. `null`) means “no progress”. `label` optional, at most 60 characters, replaces the name under the placeholder. The display updates at most every 100 ms. |
| `bardrop.notify(text)` | | Short note at the top of the shelf, about 2 seconds. At most 40 characters; the line is narrow, at the default size about 20 are fully visible. |
| `bardrop.isCancelled()` | | `true` once the user canceled. Check it in long loops. |
| `await bardrop.sleep(ms)` | | Waits `ms` milliseconds (0 to 3,600,000). |
| `bardrop.findProgram(name)` | | Path of a program, or `null`. Searches the same places as `bardrop.run` (see there), including programs other plugins have loaded; a program from the plugin’s own `tools` only if it is already loaded. Downloads nothing, starts nothing, needs no permission. Use it instead of running `which`. |
| `bardrop.log(text)` | | Line in the plugin log (only while it is turned on, see 14), at most 300 characters. |
| `await bardrop.fetch(url, options)` | `network` | `options` optional: `method` (text), `headers` (object), `body` (text). Only `http`/`https`, 60 s timeout, user agent `BarDrop/<version>`. Returns `{status, url, headers, text}`; `headers` with lowercased names, `text` at most 20 MB. Rejected only on network errors, **not** on status 404 or 500: check `status` yourself. |
| `await bardrop.download(url, options)` | `network` | Downloads into the output folder, with progress on the placeholder. `options` optional: `name`, `method`, `headers`. File name: `name`, else the server’s suggestion, else the last part of the address (cleaned, 9.4). Returns the path. Rejected on network errors or a status outside 200 to 299. |
| `await bardrop.run(command, args, options)` | `run` | Starts a program and waits until it ends. `command`: an `id` from `tools`, an absolute path, or a name looked up in the plugin’s own programs, then `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, `/opt/homebrew/bin`, `/usr/local/bin`, then the program folders in the home folder (`~/.<name>/bin`, `~/.local/bin`, where many runtimes install without Homebrew), and last the programs other plugins have already loaded. Use `bardrop.findProgram` to check first. `args`: a list, every element becomes text; there is **no shell** (no wildcards, no redirection; use `"/bin/sh", ["-c", "…"]` for that). Working folder is the output folder. Environment: BarDrop’s, plus `PATH` = the search locations above in the same order (so a program that looks for another one, like `which`, finds the same), `BARDROP_OUTPUT` = output folder. No input (stdin empty). `options.onOutput(line)` is called for every line of stdout and stderr, each split on its own; lines end at `\n` **and** `\r`, empty lines are dropped, lines over 64 KB are split. All lines arrive before `run` returns its result. An error in `onOutput` ends the whole run with that error. Returns `{code, stdout, stderr}` (at most 1 MB each). A code other than 0 is **not** rejected: check `code` yourself. Rejected if the program isn’t found, can’t start, the permission is missing or the run was canceled. |
| `bardrop.setClipboard(text)` | `clipboard` | Puts text on the clipboard. |
| `bardrop.settings` | | Values of the settings (3.3) and `replaceOriginal`. |
| `bardrop.language` | | `"de"` or `"en"`, like the app. |
| `bardrop.appVersion` | | e.g. `"1.31.0-beta.2"`. |
| `bardrop.plugin` | | `{id, version}`. |

### 9.4 File names

For `writeFile`, `writeData`, `createLink` and `download`: only the last part of a path counts; `/` and `:` become `-`, line breaks become spaces; spaces at the ends are removed; leading dots are removed; at most 80 characters (longer names are shortened before the extension, so `.txt` or `.webloc` stays); empty becomes “Item” (or “Objekt” in German). Programs that write into the output folder themselves aren’t affected.

## 10. Catalog (gallery)

The catalog lives on its own branch **`plugin-katalog`** of this repository: `https://raw.githubusercontent.com/zzuuuiii/BarDrop/plugin-katalog/index.json`, with the plugins next to it under `plugins/<id>/<id>-<version>.bdrop`. The gallery isn’t edited by hand. BarDrop up to Beta 7 still reads the empty `Plugins/index.json` on `main`; it stays unchanged.

**Add plugins through `Plugins/`** (simplest way, browser only): upload the `.bdrop` file on GitHub to the `Plugins/` folder on `main` (Add file → Upload files, commit). The workflow `plugin-gallery.yml` (`scripts/build_gallery.py`) copies it to `plugin-katalog` in about a minute; a push that only changes `Plugins/` doesn’t build an app release.

* Every `.bdrop` in `Plugins/` (subfolders included) is checked as with `check_plugin.py`. Files with errors are skipped and reported as errors in the run; the run then fails, the others are added anyway.
* The file is taken over unchanged. If the same `id` is there more than once, the highest `version` wins.
* Update: upload a new file with a higher `version`. `updated` changes only when the checksum changes.
* Remove: delete the file. The entry stays with `removed: true`.
* `category` comes from an optional `category` key in manifest.json (BarDrop itself ignores it), `standard` is set in the catalog only; both are kept on updates.
* Which ids come from `Plugins/` is stored in `from-main.json` on `plugin-katalog`. The workflow leaves entries made with `publish_plugin.py` unchanged.

**Add plugins with the script** (command line, alternative):

```sh
python3 scripts/publish_plugin.py MyPlugin/ --category images           # check, pack, add
python3 scripts/publish_plugin.py MyPlugin/ --push                      # … and upload
python3 scripts/publish_plugin.py MyPlugin/ --standard                  # installed for everyone
python3 scripts/publish_plugin.py --remove io.github.name.plugin --push # withdraw
```

The script checks like `check_plugin.py` (and stops on errors), requires a higher `version` than the catalog has, packs the plugin, removes older versions, computes the checksum and writes the entry. The catalog is checked out as `.katalog/` next to the project (a Git worktree, created the first time, listed in `.gitignore`).

```json
{
  "schema": 1,
  "plugins": [
    { "id": "io.github.name.plugin", "version": "1.0.0",
      "name": { "en": "Name", "de": "Name" },
      "description": { "en": "…", "de": "…" },
      "icon": { "symbol": "link", "color": "#34C759" },
      "url": "https://raw.githubusercontent.com/zzuuuiii/BarDrop/plugin-katalog/plugins/io.github.name.plugin/io.github.name.plugin-1.0.0.bdrop",
      "sha256": "checksum of the .bdrop", "size": 4812, "toolsSize": 61200000,
      "category": "links", "author": "Name", "homepage": "https://…",
      "permissions": ["network"], "tools": ["mytool"], "updated": "2026-10-22",
      "standard": false, "removed": false, "minAppVersion": "1.31.0" }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `id`, `version`, `name`, `url`, `sha256` | Required. `id` must equal the manifest `id`, and the checksum must match the file exactly; otherwise nothing is installed. |
| `description`, `icon`, `author`, `homepage`, `minAppVersion` | from the manifest |
| `category` | optional: `images`, `links`, `documents`, `text`, `media`, `files` or `other` (for later; the gallery doesn’t group by it yet) |
| `permissions`, `tools` | from the manifest. Before loading, the gallery shows “Offline”, “Program” (downloads a program once, then offline) or “Internet”, each with a symbol. Without `permissions` it shows none of this. |
| `size` | size of the `.bdrop` in bytes |
| `toolsSize` | size of the programs in `tools` as they end up on the Mac (the script asks their addresses, for ZIP archives it reads the unpacked file). The gallery shows both separately: “8 KB + 61 MB”. |
| `updated` | date of this version |
| `downloads` | how often the plugin was downloaded, all versions together (counted by GitHub on the files of the `plugin-galerie` release, written daily by `scripts/gallery_downloads.py`); the five most downloaded show on the start page |
| `added` | date the plugin first appeared in the gallery; stays the same for new versions (shown as new for two months) |
| `standard`, `removed` | see below |

* Checked every three hours, only while plugins are turned on; right away when turning them on; when opening Settings → Plugins if the last check is more than a minute old. New versions install by themselves. The last downloaded catalog is available right after launch. A plugin counts as new for two months after `added` (otherwise `updated`).
* `standard: true`: installed automatically (turned off), updated silently as soon as `version` is higher, can’t be edited or removed. Without internet it appears as “Not downloaded yet” with “Try Again”.
* If no plugin is installed yet, Settings → Plugins shows the available ones right away under “Available”. Otherwise “More plugins” (with the number of new ones on the right) leads there; the list shows all entries not installed yet (with a search field from seven on), each with its name, “Offline”, “Offline after setup” (downloads a program once) or “Uses the internet”, its size and “Get”; the description shows on hover. After “Get” the plugin gets all its access right away, without an allow window (see 6); then it is on, set up according to `defaults`, and its page opens.
* `removed: true`: standard plugins are removed at the next check; others disappear from the gallery but stay installed.
* Entries with a `minAppVersion` newer than BarDrop are skipped.
* Settings → Plugins works like System Settings: the list shows turned-on plugins first, each with name, version and size (or what needs attention) and “On” or “Off”; clicking opens its page, and ‹ in the title bar (or Esc) goes back; clicking “Plugins” in the sidebar again returns to the start page. The page starts with a card showing the icon, name, description and switch; below it in the same card, when needed, “Running” (with “Stop”) and “Last run failed” (with “Copy Error”; the message shows on hover). Then “Behavior” (When dropped, Replace original; explanations in the info button), the plugin’s settings and Info: Internet (“No”, “Once, for programs” or “Yes”), Works with, Programs (size, “Update” downloads their latest version) and Access; version, developer and size are a gray line below. Below the list, “Gallery” with the five most downloaded plugins to get right there and “More plugins” below them (on the right the number of plugins that are at most two months new; in the gallery they carry “NEW”). A downloaded plugin then shows under “Installed”, and its page opens. With no plugins installed, only “Installed” is missing. At the very bottom, the “Advanced” card: “Install from file” with “Import” and, collapsed under “Troubleshooting”, the “Plugin log” switch (see 14; when on, also “Save Log”). A removed gallery plugin shows under “Gallery” again right away.
* Submit with a pull request that adds the `.bdrop` to `Plugins/` on `main`; every plugin is reviewed before it is merged. Everything in `Plugins/` is public.

## 11. Checking before sharing

```sh
python3 scripts/check_plugin.py MyPlugin/          # check a folder
python3 scripts/check_plugin.py MyPlugin/ --pack   # check and write the .bdrop
python3 scripts/check_plugin.py MyPlugin.bdrop     # check a finished file
```

It checks every rule from 2 to 7, warns about calls that don’t exist in JavaScriptCore, compares the calls used with `permissions`, and checks the syntax with Node.js if it is installed, as a classic script like BarDrop does. It checks link patterns by the rules of macOS (ICU): `(?<name>…)` works, Python’s `(?P<name>…)` and `{,3}` don’t. With `--pack`, hidden files and folders (`.git`, `.DS_Store`) stay out.

**Then by hand:**

1. Import it in BarDrop and turn it on.
2. Try it with a right-click on a matching item; if it doesn’t appear, `match` doesn’t match.
3. Errors appear under Settings → Plugins → plugin → “Last error” and in the log.
4. More detail: Settings → Plugins → Advanced → Troubleshooting → “Plugin log”, then `bardrop.log`/`console.log` in the script (section 14).
5. Only then try “Automatically when dropped”.

## 12. Common mistakes

| Mistake | Effect | Correct |
| --- | --- | --- |
| `"version": 1.0` (number) | manifest unreadable | `"version": "1.0"` |
| `"value": 1080` in `options` | manifest unreadable | `"value": "1080"` |
| unknown permission, e.g. `"files"` | plugin rejected | only `network`, `run`, `clipboard` |
| `bardrop.run` without `"run"` | error on the call | add the permission |
| `tools` without `"run"` | program can’t start | `"permissions": ["run"]` |
| `"hosts": ["https://example.com"]` | never matches | `"hosts": ["example.com"]` |
| `"patterns": ["\.pdf$"]` | invalid JSON | `"\\.pdf$"` |
| `extensions` for links | only matches `webloc` | `links.hosts` or `links.patterns` |
| global `fetch` | script error | `bardrop.fetch` |
| running `which` to find a program | doesn’t find everything | `bardrop.findProgram` |
| tip appended to the error message | shows as one block under “Last error” | `throw { message, hint }` |
| `fetch` without checking `status` | error page as result | `if (r.status !== 200) throw new Error(…)` |
| `run` without checking `code` | failure goes unnoticed | `if (r.code !== 0) throw new Error(r.stderr)` |
| result outside the output folder | doesn’t appear | always write to `bardrop.outputDirectory` |
| temporary files in the output folder | appear as items | delete them or start their names with `.` |
| archive as `tools.url` | not executable | a single executable file |
| `automaticByDefault` with `network` | has no effect | `defaults.automatic` (applies after allowing) |
| script edited | all permissions gone | expected; allow again |

## 13. Example: remove tracking from links

`manifest.json`:

```json
{
  "schema": 1,
  "id": "io.github.name.clean-link",
  "name": { "en": "Clean Link", "de": "Link bereinigen" },
  "description": { "en": "Removes tracking from links", "de": "Entfernt Tracking aus Links" },
  "version": "1.0.0",
  "icon": { "symbol": "link", "color": "#34C759" },
  "minAppVersion": "1.31.0",
  "match": { "links": { "hosts": ["*"] } },
  "triggers": ["menu", "automatic"],
  "automaticByDefault": false,
  "canReplaceOriginal": true
}
```

`main.js`:

```js
function run(item) {
  if (item.kind !== "link") return;
  var hashAt = item.url.indexOf("#");
  var hash = hashAt >= 0 ? item.url.slice(hashAt) : "";
  var rest = hashAt >= 0 ? item.url.slice(0, hashAt) : item.url;
  var queryAt = rest.indexOf("?");
  if (queryAt < 0) return;                       // nothing to do: no result
  var keep = rest.slice(queryAt + 1).split("&").filter(function (pair) {
    return pair && !/^(utm_|fbclid=|gclid=|mc_)/.test(pair);
  });
  var clean = rest.slice(0, queryAt) + (keep.length ? "?" + keep.join("&") : "") + hash;
  bardrop.createLink(clean, item.name);
}
```

## 14. Plugin log

Settings → Plugins → Advanced → Troubleshooting → “Plugin log” (off by default; when on, also “Save Log”), built like the diagnostic log: turning it on shows a note on what is recorded; “Save Log” saves it as a text file wherever you like; turning it off deletes it. The file is `~/Library/Logs/BarDrop/Plugins.log` (from 2 MB on it becomes `Plugins-alt.log`; “Save Log” includes both).

It is **separate from BarDrop’s diagnostic log**: its own file, its own switch, available in all versions. Plugin events appear only here, not in the diagnostic log. Unlike that one, it names files, addresses and error messages. It stays on the Mac.

Every line: time, plugin (or program), kind, text. Kinds:

| Kind | When |
| --- | --- |
| `start` | a run begins: version, by hand or automatic, whether it replaces the original, item |
| `ok` | a run finished, with the names of the results |
| `fehler` | a run failed, with the message; also when an automatic run couldn’t start |
| `abbruch` | canceled by the user |
| `recht` | permission allowed, not allowed, or missing for an automatic run |
| `programm` | program started (with arguments), ended (code, duration, last lines of stderr), downloaded, shared from another plugin, updated, checksum wrong; `findProgram` with its result |
| `hinweis` | the `hint` of a failed run |
| `netz` | `fetch` and `download`: domain and status or error |
| `skript` | `bardrop.log` and `console.log` |
| `install` | plugin installed, updated or removed |
