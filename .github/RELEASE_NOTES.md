* **New: Popular plugins on the start page.** Settings → Plugins shows the five most downloaded gallery plugins with “Get”; a new plugin opens its page right away, and plugins count as new for two months
* **New: Plugins update by themselves.** Gallery plugins are checked every few hours and when you open Settings → Plugins, so “More plugins” is always ready. A plugin without permission is off instead of “On” with “Needs your permission”
* **New:** Hold `⌘` and drag a corner or side of the shelf to change its size, like a window, docked and detached
* **Changed: Calmer, more compact settings.** Explanations moved into info buttons, shorter and consistent names, one heading per card everywhere, short choices as segmented controls and the rest as menus, and better contrast in Dark Mode, also over light desktops
* **Changed:** “Add Action” and “Add App” are menus with icons and groups; new actions go to the top row. “Order when dropped” is reordered by dragging like the actions, and import and plugin log sit in an “Advanced” card
* **Changed:** Pulling the shelf off the edge, opening it and resizing it are smoother. From macOS 26, the settings use the system’s own controls with Liquid Glass, including a real glass Back button
* **Fixed:** The Back button no longer moves the Settings window, `⌘C`, `⌘V` and `⌘A` work in Settings, the bar under the title stays on plugin pages, and the lock screen no longer reacts at the screen edge
* **Fixed:** `bardrop.createLink` uses only the last part of a title, and long file names keep their extension (#58)
* Releases can be signed with a fixed certificate so macOS keeps permissions such as Desktop access across updates (`scripts/sign_app.sh`)

<!-- de -->

* **Neu: Beliebte Plugins auf der Startseite.** Einstellungen → Plugins zeigt die fünf meistgeladenen Plugins der Galerie mit „Laden“; ein neues Plugin öffnet gleich seine Seite, und Plugins gelten zwei Monate lang als neu
* **Neu: Plugins aktualisieren sich von selbst.** Galerie-Plugins werden alle paar Stunden und beim Öffnen von Einstellungen → Plugins abgefragt, „Weitere Plugins“ ist dadurch immer gleich da. Ein Plugin ohne Erlaubnis ist aus statt „Ein“ mit „Braucht deine Erlaubnis“
* **Neu:** Mit gedrücktem `⌘` an einer Ecke oder Seite der Ablage ziehen ändert ihre Größe wie bei einem Fenster, angedockt und losgelöst
* **Geändert: Ruhigere, kompaktere Einstellungen.** Erklärungen in Info-Knöpfen, kürzere und einheitliche Namen, überall eine Überschrift je Karte, kurze Auswahlen als Umschalter und der Rest als Menü, besserer Kontrast im Dunkelmodus, auch vor hellem Schreibtisch
* **Geändert:** „Aktion hinzufügen“ und „App hinzufügen“ sind Menüs mit Symbolen und Gruppen; neue Aktionen kommen in die obere Reihe. „Reihenfolge beim Ablegen“ ordnet man per Ziehen wie die Aktionen, Importieren und Plugin-Protokoll stehen in der Karte „Erweitert“
* **Geändert:** Ablage vom Rand ziehen, öffnen und in der Größe ändern läuft flüssiger. Ab macOS 26 nutzen die Einstellungen die Bedienelemente des Systems mit Liquid Glass, auch einen echten Zurück-Knopf aus Glas
* **Behoben:** Der Zurück-Knopf verschiebt das Einstellungsfenster nicht mehr, `⌘C`, `⌘V` und `⌘A` gehen in den Einstellungen, die Leiste unter dem Titel bleibt auf Plugin-Seiten, und auf dem Sperrbildschirm reagiert der Bildschirmrand nicht mehr
* **Behoben:** `bardrop.createLink` nimmt nur den letzten Teil eines Titels, und lange Dateinamen behalten ihre Endung (#58)
* Releases lassen sich mit einem festen Zertifikat signieren, damit macOS Freigaben wie den Zugriff auf den Schreibtisch über Updates behält (`scripts/sign_app.sh`)
