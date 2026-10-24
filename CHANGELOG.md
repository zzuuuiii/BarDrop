# Changelog

## 1.31.0-beta.10
* **New: Popular plugins on the start page.** Settings → Plugins shows the five most downloaded gallery plugins with “Get”; a new plugin opens its page right away, and plugins count as new for two months
* **New: Plugins update by themselves.** Gallery plugins are checked every few hours and when you open Settings → Plugins, so “More plugins” is always ready. A plugin without permission is off instead of “On” with “Needs your permission”
* **New:** Hold `⌘` and drag a corner or side of the shelf to change its size, like a window, docked and detached
* **Changed: Calmer, more compact settings.** Explanations moved into info buttons, shorter and consistent names, one heading per card everywhere, short choices as segmented controls and the rest as menus, and better contrast in Dark Mode, also over light desktops
* **Changed:** “Add Action” and “Add App” are menus with icons and groups; new actions go to the top row. “Order when dropped” is reordered by dragging like the actions, and import and plugin log sit in an “Advanced” card
* **Changed:** Pulling the shelf off the edge, opening it and resizing it are smoother. From macOS 26, the settings use the system’s own controls with Liquid Glass, including a real glass Back button
* **Fixed:** The Back button no longer moves the Settings window, `⌘C`, `⌘V` and `⌘A` work in Settings, the bar under the title stays on plugin pages, and the lock screen no longer reacts at the screen edge
* **Fixed:** `bardrop.createLink` uses only the last part of a title, and long file names keep their extension (#58)
* Releases can be signed with a fixed certificate so macOS keeps permissions such as Desktop access across updates (`scripts/sign_app.sh`)

## 1.31.0-beta.9
* **New: AirDrop into the shelf.** “Add files received with AirDrop” (Settings → Items) puts files that arrive via AirDrop into the shelf right away. They stay in the Downloads folder
* **New: Plugins start ready to use.** A plugin can come with default settings (action bar, automatically when dropped, replace original). After you install and allow it, it is turned on with these settings, and the gallery opens its page
* **New:** A `.bdrop` file added to the `Plugins/` folder of the repository appears in the gallery for everyone
* **Changed: Calmer plugin settings.** The list shows version and size for each plugin. A plugin’s page shows permission, running and errors as quiet rows in its top card (“Copy Error” instead of the whole message), short descriptions instead of info buttons, and a short Info that says clearly whether the plugin uses the internet. “Access” replaces “Permissions” and can revoke everything at once. The gallery shows two lines per plugin and only plugins you don’t have yet. Log and “Import From Files” sit at the bottom right
* **Changed:** A running plugin shows a blue progress bar like the Finder, centered between the picture and the name, and breathes calmly instead of flickering
* **Changed:** Clearer wording throughout Settings, in English and German
* **Changed:** The light outline of the shelf sits fully on the black instead of half on the edge, and a floating glass shelf no longer shows a double edge
* **Changed:** Everything at the top right of the shelf has the same distance from the edge as “BarDrop” on the left
* **Fixed:** If macOS doesn’t let BarDrop read the screenshot folder (for example after an update), Settings say so and open the right place in System Settings, instead of screenshots silently not arriving
* **Fixed:** Canceling a plugin with “Replace original” no longer brings the original back
* **Fixed:** Plugin actions in the action bar accept files dragged from the Finder (#57)
* **Fixed:** The plugin icon in the allow window no longer has a square around it
* Plugins: new `defaults` key in manifest.json; `scripts/build_gallery.py` builds the gallery from `Plugins/`

## 1.31.0-beta.8
* **New: Plugin settings like System Settings.** The list shows each plugin with On or Off. A click opens its own page: the switch at the top, when it runs, its settings, and Info with internet use, size, programs and permissions at the bottom. `‹` in the title bar, `esc` or another click on Plugins in the sidebar goes back. Without installed plugins, the available ones show right away
* **New: Plugin gallery.** “More Plugins” lists reviewed plugins and shows before loading whether each works offline, downloads a program once or uses the internet, and how big it is. Plugins from the gallery get updates from it
* **Changed: One window for permissions.** A plugin asks once for everything it needs (notice, permissions, programs) before its first run, never in the middle of it. Installing a `.bdrop` file already allows what its window lists, putting text on the clipboard no longer asks, and a failed run no longer opens a window: the placeholder shakes and the message is on the plugin’s page
* **Changed:** The plugin log works like the diagnostic log: a note when you turn it on, “Save Log” to keep a copy, and turning it off deletes it
* **Changed:** A running plugin shows a thin progress bar between the picture and the name, and the icon or preview of the file it is creating. A failed run shakes briefly before it disappears, and a run that ends right away no longer flashes a placeholder
* **Changed:** While Settings are open, BarDrop shows in the Dock and in `⌘⇥` like any app, so the window behaves like a normal window, also after Control Center. In Settings, `↑` and `↓` move through the sidebar
* **Changed:** A floating shelf follows changes in Settings right away: size, icon sizes, action names and “Translucent when floating” apply where it is. In light mode, the shelf turns from black straight to light glass when you pull it off
* **Fixed:** Images dragged from the web, such as from an image search, land in the shelf as images instead of links, and new items appear right away instead of only after a click
* **Fixed:** Pulling the shelf off the edge quickly no longer leaves pieces of the edge shape on the floating shelf, and without glass it is fully black
* **Fixed:** Controls in Quick Look (playing videos and sound, the buttons at the top) no longer close Quick Look and the shelf; the shelf closes only after Quick Look
* **Fixed:** If the display with a floating shelf is unplugged, the shelf goes back to its edge instead of getting stuck on another display
* **Fixed:** A canceled plugin stops computing, even in an endless loop, instead of keeping the Mac busy until BarDrop quits
* **Fixed:** Programs started by plugins get their arguments exactly as given and always get UTF-8 text, so accented letters and emoji no longer turn into “?”
* Plugins: scripts can use `URL`, `URLSearchParams`, `setTimeout`, `setInterval`, `queueMicrotask`, `TextEncoder`/`TextDecoder` and `atob`/`btoa`; new `bardrop.readData` and `bardrop.writeData` for bytes, `bardrop.findProgram` to find programs, `"batch": true` for one run with all selected items, and `throw { message, hint }` for a tip with an error
* Plugins: plugins share a program another plugin already downloaded from the same address, and “Update” on a plugin’s page downloads its programs again
* `scripts/publish_plugin.py` checks, packs and adds a plugin to the gallery, including the size of its programs

## 1.31.0-beta.7
* **New: Pull the shelf off the edge.** Grab the handle at the top of the open shelf and pull: it stretches like a drop, comes loose with a light tap on the trackpad and floats above all windows. Let go near the left or right edge and it docks there; the edge in Settings follows along. `esc`, the keyboard shortcut or “Back to the Edge” in the right-click menu return it
* **New: Shortcuts as actions.** Add Action → Shortcut puts any of your shortcuts into the action bar. Drop files on it to run the shortcut with them; files it returns land in the shelf
* **New: Unzip right in the shelf.** Right-click a ZIP archive and choose Unzip, or double-click it. Several items become a stack next to the archive, a single item lands on its own
* **New:** “Translucent when floating” (Settings → Style) turns a floating shelf into dark glass, a little lighter in light mode. Off by default: the floating shelf is deep black like at the edge
* **New:** Dragging a stack out shows one image with the number of items instead of many single ones
* **New:** A floating shelf gives a light tap on the trackpad when files can be dropped on it
* **Changed: Items react like in the Finder.** Only the picture and the name of an item respond to clicks; a click next to them clears the selection or starts a selection rectangle. Rows sit a little closer together
* **Changed:** The introduction is new and calmer: drop, pointer, take out, actions and keyboard shortcut, step by step. “Open at login” comes at the end and is on by default
* **Changed:** Hold `⌘` and drag an action to move it, also into the other row. An action dragged out with `⌘` leaves its place empty and slides back in one move if you put it back
* **Fixed: Everything appears right away.** Images from the web, the first item in an empty shelf and opened folders show up at once instead of only after a click or reopening. Opening a folder no longer freezes the shelf while macOS asks for permission
* **Fixed:** A right-click works the first time, also right after the shelf opens or when BarDrop isn’t in front
* **Fixed:** Settings no longer jump to the front by themselves after Control Center, and a floating shelf leaves Control Center open
* **Fixed:** Switching between left and right no longer flashes the shelf in the middle of the screen
* **Fixed:** A selection rectangle over many items keeps the upper items selected while you keep dragging
* New screenshots also arrive after you change where macOS saves them
* Settings: clearer texts and settings that no longer did anything removed

## 1.31.0-beta.6
* **New:** Folders open right in the shelf, like a stack: click a folder in the action bar, or double-click a folder in the shelf (or press `↩`). Select, drag out, Quick Look, copy and move to the Trash work like in the Finder, a double-click opens subfolders, and files you drop there go into the folder. The header shows the folder’s name, `esc` goes back one level, and `⌘Z` puts files moved to the Trash back into the folder
* **New:** “Open shelf” has a new option “Instantly” that opens the shelf the moment the pointer reaches the edge, without the strip first. Every option shows a word and its wait, such as “Quick (0.3 s)”, which stays the standard
* **Changed:** Clicking an action no longer runs it on the selected items; drag items onto it instead. Clicking an app opens it, clicking a folder shows its contents, and the action grows briefly
* **Changed:** Settings are tidier. “Position along the edge” is Fixed or Follows pointer; with Follows pointer a slider sets how much of the edge reacts (standard: two thirds in the middle). General fits on one card, “Open where you left off” is under Opening, exceptions are together, and new screenshots are under Storage
* **Changed:** “After use” offers Keep in the shelf (new standard), Remove after dragging out and Always remove. If you had chosen “Remove after actions”, your items now stay in the shelf
* **Changed:** The shelf’s title is always BarDrop, and the newest items always come first. “Never” is gone from “While dragging files”, the strip’s edge curve is fixed, and “Group into a stack” offers 2, 3, 5 or 10 items. The size sliders are called “Item size” and “Action size”; actions can be a little bigger (up to 54 pt)
* **Changed:** Shorter notes at the top right of the shelf, such as “Removed”, “Copied” or “3 selected”. While plugins run, it says “Plugin running”
* **Changed:** Right-click menus no longer show icons, also for plugins
* **Fixed:** Quick Look with `space` works reliably, even when pressed quickly several times: the shelf keeps the focus, so `space` no longer reaches the window behind, and Quick Look no longer shows “No Items Selected”. The arrow keys go through the items. A click in another app closes Quick Look and the shelf, and after closing Quick Look the shelf closes as usual when the pointer is elsewhere
* **Fixed:** Settings no longer jump to the front by themselves after a right-click in the shelf, Quick Look, sharing, Mail, Messages or questions from the shelf, and they are active again after closing Control Center or Notification Center
* **Fixed:** Scrolling fast with momentum no longer skips items and jumps to the end
* **Fixed:** While the shelf opens, items no longer shine through the action bar
* **Fixed:** Moving the pointer quickly along the edge opens the shelf: the strip follows the pointer while it is visible
* **Fixed:** Without “Open where you left off”, an open stack or folder closes only once the shelf is out of sight
* Opening a folder starts at the top and looks the same whether it is pinned or in the shelf. Clicking a pinned folder that is already open keeps it open; from a subfolder it goes back to its top level
* Settings: cards and pop-up lists are a little see-through, switches slide reliably to the new choice, the keys in the shortcut list show centered symbols, and the BETA label is a calm gray, centered next to “Plugins”
* Introduction: the screen dims more gently, choosing left or right works with one click, a single quiet arrow points to the edge, and the trackpad gives a light tap when the photo reaches the shelf
* Texts in English and German say the same thing everywhere; English uses American spelling
* Plugins: the placeholder shows a preview of the file the plugin works on. It starts out see-through, becomes solid with the progress, and shows the result as soon as a finished file is there. Hovering shows Pause or Resume and × to cancel; placeholders can be selected like other items, and `⌫` cancels them
* Plugins: consent, permissions and programs are asked in one short window instead of up to four in a row. Importing shows a short list; the script is under “View Script”
* **Fixed:** Plugins: Cancel takes effect at once, even for a plugin stuck in an endless loop; programs that ignore the request to quit are ended after 3 seconds. Turning off or removing a plugin cancels its jobs
* Plugins: permissions now cover all files of a plugin, so after this update plugins ask for their permissions once more. Permission to download a program is tied to its address, plugins with the same program name no longer overwrite each other, and a changed consent text asks again
* Plugins: packages may be at most 20 MB unpacked, `*.example.com` in `links.hosts` works, and a plugin without a known trigger is rejected instead of never showing up
* Plugins: `const run = …` and `let run = …` work like `function run`; new `bardrop.pluginDirectory`; `createLink` only accepts web addresses; `bardrop.notify` takes at most 40 characters
* Plugins: each run has its own internet session, and automatic runs use the current code after an edit
* `check_plugin.py` checks scripts the way BarDrop loads them, checks link patterns by macOS rules, and no longer packs hidden folders such as `.git`

## 1.31.0-beta.5
* Plugins: an automatic plugin that is missing a permission (for example after an update of the plugin) now asks for it when you drop something, instead of silently not starting
* Plugins: while a program is downloaded for a plugin, the placeholder shows the progress in percent; the plugin log notes the size and how long it took

## 1.31.0-beta.4
* **New:** Plugin log. Settings → Plugins → Log keeps a separate file of what each plugin did: starts, results, errors, permissions, downloaded programs, programs run and internet requests. It is kept apart from BarDrop’s diagnostic log, is off by default, and stays on this Mac. `bardrop.log` and `console.log` now write there
* Plugins in Settings carry a BETA label
* Plugins: programs a plugin downloads (`tools`) can come as a ZIP archive (`archive`, `executable`), and `{arch}` picks the file for Apple chip or Intel Macs. Each plugin finds its own programs by name
* **Changed:** Plugins with “Replace original” turned on no longer show the original next to a placeholder: the placeholder stands in the original’s place, and the result appears there directly, without a fade
* Plugins: messages a plugin gives itself (`throw new Error(…)`) appear exactly as written; file and line are only added for errors in the code
* **Improved:** macOS sometimes reports changed displays many times per second without anything changing (over 200 times in 30 seconds in a diagnostic log). BarDrop now collects these reports and only rearranges the shelf when something really changed, which saves work and keeps the diagnostic log readable
* **Improved:** Files for which Quick Look can’t make a preview, such as links, are no longer asked for a preview again and again

## 1.31.0-beta.3
* The action bar has no line above it anymore: items simply disappear under the bar
* Plugins: errors show the file and line in the script (for example “TypeError: … (main.js:4)”), and all messages of the plugin interface are in English and German
* Plugins: Pause and Cancel also stop programs that a plugin’s program started itself
* Plugins: output of programs is split into lines separately for stdout and stderr, so lines no longer get mixed up
* Plugins: the same plugin doesn’t start twice for the same file; waiting plugins show a clock and can only be cancelled
* Plugins: while a program is downloaded for a plugin, the placeholder says so; the dialog now says that the program runs with the same rights as the plugin
* Plugins: permission dialogs ask a clear question (“Allow … to access the internet?”); Settings → Plugins has “Allow” for missing permissions, and plugins that can’t be read can be shown in the Finder or removed
* Plugins: `readFile` accepts paths relative to the output folder; `writeFile` and `readFile` check their arguments
* Plugins: “Works with” uses the language of BarDrop

## 1.31.0-beta.2
* **Fixed:** Links dragged from a web page together with a preview image are kept as a link when a turned-on plugin is made for that link, instead of saving the preview image
* **Fixed:** Plugins that run automatically and need a program (`tools`) no longer fail silently on their first run. Turning on “Automatically when dropped” now also asks whether the program may be loaded; plugins whose automatic mode was turned on in Beta 1 ask once at the next drop
* Settings → Plugins shows the last error of a plugin, with Copy
* Plugin scripts can use `console.log`; it goes to the diagnostic log like `bardrop.log`
* Two plugins that need the same program at the same time no longer load it twice
* docs/PLUGINS.md is now an exact reference, with a checker for plugins (scripts/check_plugin.py)

## 1.31.0-beta.1
* **New:** Plugins. Settings → Plugins (off by default) adds your own steps as `.bdrop` files: in the right-click menu below the usual entries, in the action bar, or automatically when you drop a matching file type or link. Plugins are written in JavaScript, ask for permissions (internet, running programs, clipboard) the first time they need them, and put their results right next to the original. BarDrop doesn’t come with any plugin; how to write one is in docs/PLUGINS.md
* While a plugin runs, a placeholder with a ring stands next to the original; its right-click menu shows the progress in percent and can pause, resume and cancel
* Double-clicking a `.bdrop` file shows what the plugin wants to do and its script before anything is installed
* ⌘I (and Get Info in the right-click menu) opens the Finder’s Info window for the selected items
* The action bar has a clean edge instead of the soft fade above it

## 1.30.0
Everything since 1.29.0:

### New
* New introduction: a short presentation with one scene per step and small exercises (drop, actions, shortcut, opening with the pointer)
* Move to Trash like in the Finder: ⌘⌫, the Trash action and the right-click menu. ⌘Z puts the files back where they were and into the shelf
* Items → Storage → Files from the Finder: “Use original” (new default) or “Keep a copy”
* Icon size for the files in the shelf (Appearance) and for the action bar (Actions)
* Appearance → Title: “BarDrop”, “Shelf” or “None”; Actions → Show names: “All”, “Folders Only” or “None”
* Items → Order → “Open where you left off” and Opening → When → “Small hit area”
* Language “System”: BarDrop follows macOS (German or English, otherwise English)
* Sounds like in the Finder for removing, the Trash and folder actions
* Red badge next to About BarDrop when an update is available
* Beta versions: optional, anonymous diagnostic log in Settings → About BarDrop

### Improved
* Folder actions work like dropping onto a folder in the Finder: on the same disk they move, on another disk they copy; ⌥ always copies, ⌘ always moves
* New defaults for everyone who never changed them: language follows the system, Remove automatically “Never”, height 340 pt, all actions in the lower row, not over full-screen apps. Values you set yourself stay. New installations open at login
* Previews appear right away, a quick one first and then the sharp one, instead of the file icon
* Selection like in the Finder; the selection rectangle scrolls the shelf, and arrow keys keep the selected item visible and move through items in Quick Look
* The Trash action looks full or empty like the Trash in the Dock
* Settings: light mode in the macOS system colors, short choices right in the row, keyboard shortcuts as key caps, all panes in one group
* Width can be set from 220 pt; Reset All Settings resets everything, including language, updates and beta versions
* Silent updates wait until a release is two days old; Install still updates right away
* Files from Photos, Mail and browsers are waited for as long as they are still being written, up to 30 minutes
* Web images keep their original format when “Save web images as PNG or JPEG” is off

### Fixed
* After unplugging an external display, the shelf works at the edge again and Settings open fully on screen
* Images from the web no longer disappear right after dropping them
* Items that can’t be read are kept instead of being lost on the next save
* Right-click menus keep their highlight and no longer lose the pointer
* New screenshots are also added when Spotlight can’t be used
* Diagnostic log: the report shows the full version, and the scenes of the introduction no longer appear as removed items

## 1.30.0-beta.23
* **Fixed:** After unplugging an external display (or unlocking the Mac with a changed arrangement), the shelf no longer reacted at the edge and Settings opened half off screen. BarDrop now always works with the current position of each display and checks it again after waking, unlocking and switching users
* Settings open centered again whenever their window no longer fits completely on a display
* Introduction: the scenes show a calm slate background like the app icon instead of the colorful gradient or the desktop picture; the shelf in the scenes always has its light outline
* Diagnostic log (beta only): changes of the displays are recorded with their arrangement
* README: colored badges

## 1.30.0-beta.22
* Introduction: no more cut-out in the dimmed background behind the window (it lagged behind when you moved the window)
* “Remove from Shelf” plays its sound at half the volume
* Icons in the Settings sidebar and on the last page of the introduction have a slight shadow
* Diagnostic log (beta only): every error is recorded with its code, a readable name, the system’s message (names and paths hidden) and the place in the code where it happened; uncaught exceptions and macOS crash reports of BarDrop are included in the saved log. Quick Look’s harmless “no cached preview” for the fast first preview is marked as normal
* README: new pictures of an action in use and of the whole Settings window

## 1.30.0-beta.21
* **Changed:** BarDrop opens at login by default; it is turned on at the first launch (turn it off in the introduction or in Settings → General). Reset All Settings turns it back on
* **Changed:** All actions are in the lower row by default (for everyone who never moved them)
* **Changed:** Opening → When → “Small hit area”: when on, also dragged files must reach the strip itself before the shelf opens
* Introduction: the shelf stays open the whole time you drag the photo, also while it is still far from the edge
* Introduction: the dimmed background is cut out behind the window, so the window is as see-through as Settings; the cut-out moves with the window
* Introduction: files can’t be dropped onto the dimmed background or the apps behind it, so the photo can’t get lost; actions only accept the photo in the step that asks for it (only the Trash), and no stacks are formed
* Introduction: changing the screen edge takes one click (the first click was sometimes lost)
* Introduction: And There’s More shows six features: Keys like in the Finder, Pin, Convert, Stacks, Screenshots and Cleanup (both marked as optional)
* Changing the icon size of the actions shows the change live in the shelf at the edge
* Icons in Settings and the introduction have a slight gradient, lighter at the top
* Beta versions: optional diagnostic log in Settings → About BarDrop. Off by default; turning it on shows what it records. Detailed but anonymous (no file names, paths or contents), stays on your Mac, “Save Log” creates a text file you can pass on
* README: privacy section explains the diagnostic log; features updated

## 1.30.0-beta.20
* **Changed:** Introduction: the shelf opens when you click “Let’s Go” and stays open while you drop the photo and drag it onto the Trash
* **Changed:** Introduction: new step “Open with the Pointer” near the end: a short scene shows how the shelf opens at the edge without a file, then you try it
* Introduction: the exercises stand freely under the text instead of in a box; the photo to drag has a soft, breathing highlight so you see it can be picked up
* Introduction: the Trash in the exercise looks full or empty like the Trash of your Mac; “⌘Z brings it back” stays a little longer
* Introduction: the photo to drag no longer disappears (it stays in memory, and it is created again if it was dragged somewhere else)
* Introduction: texts reworded to match what happens now; And There’s More shows Pin instead of repeating Actions
* Opening → When: the option is now called “Small hit area for the pointer”
* Right-click menus of the shelf are off while the introduction is open

## 1.30.0-beta.19
* **Changed:** Introduction: on the first page the shelf opens at the edge, so you see where it is. On the next page it closes, the strip stays, and you drag the photo in
* **Changed:** Introduction: instead of dragging the photo back out, you drag it onto the Trash in the action bar (or onto any action if the Trash isn’t there). This puts the sample photo in the Trash of your Mac; ⌘Z brings it back
* Right-click menu: “Remove from Shelf” instead of “Remove”, so it is clear the file itself stays
* Introduction: the window is exactly in the middle of the screen with the shelf (macOS places windows a little above the middle)

## 1.30.0-beta.18
* Introduction: the file to drag is a photo (“Photo.jpg”), the same sample file that appears when changing the icon size, instead of the app icon
* README: “Screenshots” link at the top and its own section; the preview loop moves the file from the desktop into the shelf and back, more smoothly

## 1.30.0-beta.17
* **Fixed:** Introduction: the shelf is above the dimmed background. The cause: the shelf window lost its level when it was set up as a floating panel, so it sat below the background (and below other floating windows)
* Opening → When → “Pointer only on the strip itself”: without a file, the shelf only opens when the pointer touches the strip; while dragging files the area stays generous (off by default)
* Dragging an action out of the action bar plays the sound macOS plays when an icon is removed from the Dock
* Removing from the shelf: only the first, short part of the Finder sound, right away (it faded in and rang on for over a second)
* The Trash action looks full when the Trash of your Mac has something in it, like in the Dock
* Dropped files show their preview right away: a quick preview first, then the sharp one, instead of the generic file icon first
* Introduction: the exercises are in the same cards as Settings; the drop area is a dashed well that lights up in the accent color
* Keyboard → Keyboard shortcuts lists ⌘⌫ Move to Trash
* Names: “Open in full screen” is now “Also over full-screen apps”

## 1.30.0-beta.16
* **Changed:** Reset All Settings really resets everything, including the language (back to “System”), updates and beta versions; only the items in the shelf are kept
* **Changed:** Remove automatically no longer goes into ⌘Z (it did in beta 15); copies are still deleted only after 15 minutes
* **Changed:** Two sounds: removing from the shelf (⌫, Remove, Remove All) plays the Finder sound used until beta 14, moving to the Trash (⌘⌫, Trash action, Move to Trash) the macOS sound for dragging to the Trash
* Actions → Show names: “All”, “Folders Only” or “None”; with Folders Only the other actions keep the space so all icons stay level
* Dropping into a folder of the action bar plays the macOS sound for a mounted volume
* Clicking an action inside an open stack uses the files selected in the stack (it used the selection of the shelf)
* Files dragged straight from the Finder onto the Trash action can be put back with ⌘Z and then appear in the shelf
* Introduction: the shelf stays above the dimmed background (the background could cover it when macOS reports the Dock above the menu bar)
* New screenshots: BarDrop also watches the screenshot folder itself instead of relying on Spotlight only
* Images, PDFs and videos wait briefly for their preview instead of showing the file icon first (less flicker when dropping)
* Items → Storage: “Files from the Finder” is a menu, so the row is no longer squeezed
* A copy moved out by a folder action no longer leaves an empty storage folder behind
* README: new product pictures and a new preview loop, rendered from the app itself

## 1.30.0-beta.15
* **Changed:** ⌘⌫ moves the selected items to the Trash, like in the Finder, instead of only removing them from the shelf. ⌫ still only removes. The right-click menu has “Move to Trash” (⌘⌫) under “Remove” (⌫)
* **Changed:** Folder actions work like dropping onto a folder in the Finder: on the same disk they move, on another disk they copy and the original stays; ⌥ always copies, ⌘ always moves. This applies to clicking, dragging items out of the shelf and dragging files straight from the Finder. Before, folder actions always moved
* **Changed:** Trash action and ⌘⌫ can be undone with ⌘Z: the file goes back to where it was and into the shelf. Put Back in the Finder still works
* **Changed:** Remove automatically is “Never” by default (was “After 2 hours”). When it is on, ⌘Z brings items back; copies are only deleted after 15 minutes
* **Changed:** Items → Storage → “Files from the Finder”: “Use original” (new default) or “Keep a copy”; replaces “Always store a copy”. Every action works on what is in the shelf, the original or BarDrop’s copy. Images from the web, text, links and files from browsers or apps are always stored as before
* **Changed:** Language follows the system by default (German or English, otherwise English); new choice “System”
* **Changed:** New defaults for everyone who never changed them: height 340 pt, Open in full screen off. Values you set yourself stay
* Larger hit area is always on; the setting is gone
* Position along the edge: “Follows pointer, middle third” is gone and becomes “middle half”
* Items → Order → “Open where you left off”: the shelf opens at the same scroll position and in the same stack (off by default)
* Trash sound: the short sound macOS plays when dragging to the Trash or pressing ⌘⌫ (before, the longer Finder sound)
* Selection rectangle: its end stays in the visible part of the shelf above the action bar, and the shelf scrolls along when the pointer goes further
* Action bar a little flatter; icon sizes unchanged
* Share action in the colors of the AirDrop icon
* Settings: light mode has a light background (was dark); sidebar with all panes in one group, About BarDrop at the bottom without a heading
* Width can be set from 220 pt (was 240)
* Slider marks evenly spaced (Length had two marks close together at the end)

## 1.30.0-beta.14
* Removing items (⌫, menu, Remove All) and the Trash action play the Finder’s trash sound, if interface sound effects are on in System Settings
* Quick Look: ← → ↑ ↓ move the selection in the shelf and show the newly selected item; with several selected items Quick Look pages through them itself
* Appearance → Title: “BarDrop”, “Shelf” or “None”
* Update available (regular or beta): red badge next to About BarDrop in Settings; with “Update automatically” on, opening Settings also checks quietly. No window without a click; silent installation stays as before. The “Update to …” item in the shelf menu is gone
* Selection like in the Finder: gray area about a quarter larger than the icon, name highlight slightly wider, with Finder corner radii
* Soft fade under the header while the list is scrolled, like above the action bar
* Empty shelf: icon and “Drop here” only, gray until something is dragged over, centered between header and action bar
* Light mode: Settings and introduction use macOS system colors (cards, lines, switches, segments, keys, buttons); dark mode unchanged
* Introduction: the whole screen is dimmed, including the edge (which still lets pointer and drops through), the shelf shows the light outline, strip and shelf sit in the middle of the edge, minimize is disabled
* Dragging an action out of the bar: no puff of smoke
* Choices with two options are segmented controls in both languages (Sort order was a menu in German only)
* The shelf stays open while a selection rectangle is drawn
* Icon size: the examples appear on the first slider move and stay until the shelf has fully closed
* Pinning a folder or app by dragging: no slide-in animation
* New tiles redraw when their preview or placeholder appears, also without focus (items from the web no longer vanish until the next opening)
* Open on click: the strip keeps the size set under Appearance
* Right-click menus open only once BarDrop is active (highlight follows the pointer, Convert looks the same as the menu)
* Arrow keys scroll the list so the selected item stays fully visible
* Quick Look open: a click elsewhere or switching apps closes Quick Look and the shelf
* Haptics: a strip already shown as a preview pulses when the pointer reaches it; the trackpad is reopened and the pulse repeated when the connection is lost (sleep)
* While dragging out of the shelf it fades without blur (smoother)

## 1.30.0-beta.13
* Introduction: dropping the sample image works again. The dimmed background no longer covers the edge where the shelf sits; that strip stays bright and behaves exactly as without the introduction (hovering, dragging in, opening)
* Introduction: while dropping and dragging out, the first strip stays visible at the edge in the size set in Settings, so you know where to drag; it stays while dragging and the shelf opens as usual near the edge
* Introduction: the background is tinted a little darker (42 % instead of 35 %)
* Settings and introduction: 64 % opaque instead of 62 %

## 1.30.0-beta.12
* Introduction: the dimmed background stays bright at the edge where the shelf appears, so the shelf no longer looks like it is behind everything; the bright area follows a change of edge
* Settings and introduction are a little more see-through than before beta 11 (62 % opaque instead of 70 %)

## 1.30.0-beta.11
* Introduction: while it is open, the screens behind it are slightly dimmed and clicks there no longer open another app; they bring the introduction back to the front. The shelf works as usual for the exercises
* Changing the icon size: the examples in the shelf look like real files (PDF, photo, text, folder, video, archive) with icon and name instead of empty dashed squares
* Settings and introduction are only slightly see-through (about 3.5 % instead of 30 %)

## 1.30.0-beta.10
* Changing the screen edge: the shelf disappears at the old edge right away and the strip pops out at the new edge with the normal animation, like when dragging a file in; no more jumping from side to side (also in the introduction)
* Introduction: the window is no longer cut off at the bottom, and the content starts below the window buttons
* Introduction: each exercise is on its own highlighted card with “Your turn” and a clear instruction; the sample image is the whole app icon with its name, like a file, and nudges toward the edge
* Introduction: the ⌘Z step is gone (⌘Z itself works as before); four pages remain plus And There’s More
* Introduction scenes: the dragged image goes to a free spot in the shelf instead of covering a tile; a chart instead of a text file, which was unreadable as a small tile

## 1.30.0-beta.9
* Introduction: the window always stays 680 × 620; it could grow far beyond that on some Macs, with a large empty area under the content

## 1.30.0-beta.8
* Introduction redone as a short presentation: one scene per page, a headline, one sentence and a small exercise; Back, page dots and Continue at the bottom; Welcome, Drop, Drag Out, Get Back (⌘Z), Open from Anywhere (shortcut) and And There’s More
* The scenes show the real shelf in your size, edge and animation style, with real tiles, the action bar and notices like “1 item removed”, the macOS pointer and the desktop picture (only pictures that come with macOS; otherwise a gradient)
* The demo shelf has its own list and sample files in a temporary folder and can’t trigger anything; the real shelf stays untouched
* New exercises: drag the image back out of the shelf onto the drop area, remove it and bring it back with ⌘Z, press the shortcut
* Shelf views have a demo mode without the AppKit areas for clicks, dragging and dropping (used only by the introduction)

## 1.30.0-beta.7
* New introduction built like Settings: a 680 × 620 window in the middle of the screen, the five steps in a sidebar that tick themselves off, the same cards, switches and buttons, light and dark like the system
* Introduction pages: Welcome (how it works, language, screen edge, open at login), Drop and Drag Out (one short exercise each), Shortcut (try the shortcut, the most important keys) and Discover More (action bar, stacks, convert, pin, cleanup with the current setting, Settings)
* Back and Continue at the bottom; any step can also be opened from the sidebar
* Versions read “1.30.0 Beta 7” everywhere in the app and in the titles of new GitHub releases
* All texts checked in English and German; both languages say the same, glossary in docs/GLOSSARY.md
* About BarDrop: automatic updates are described with the two-day wait; with automatic updates off, an available version no longer claims to install by itself
* Reset all settings: the dialog mentions that beta versions are kept
* Items: deletion of stored copies, images, links and text 15 minutes after dragging out or an action is described; ⌘Z brings them back within 15 minutes
* Title Case for Convert menu items (“Audio Only (M4A)”, “Plain Text (TXT)”, “MP4 (HEVC, Smaller)”) and the “Let’s Go” button
* Info.plist copyright no longer contains German text
* README: GitHub connections, Xcode 26 to build, update timing, ⌘↑ in the keyboard table; American spelling “gray”

## 1.30.0-beta.6
* Items that can’t be read are written back unchanged instead of being dropped on the next save; while there are any, or a backup of an unreadable list exists, no stored files are cleaned up at launch (the log says so)
* File promises (Photos, Mail, browsers) wait as long as the destination folder changes, at most 30 minutes, instead of a fixed 90 seconds
* Introduction: only the sample image is removed at the end; Open at login starts with the real setting when the introduction runs again, and Done with the switch off turns it off; ⌘W closes it; the sample image is named in the language chosen on the first page
* ↑ and ↓ use the real number of columns for every icon size and shelf width
* Removing the open stack leaves no hidden selection behind
* Silent updates wait until a release is 48 hours old; Install in the dialog or menu still updates right away
* Fixed a data race when dropping user files together with other items while “Always store a copy” is off
* Tests: saved shelves of every version since 1.26 must load completely

## 1.30.0-beta.5
* Right-click menus are system menus again, in the Liquid Glass look of macOS; Convert is a regular submenu next to them
* The introduction looks like the open shelf: black shape, the same tiles, fonts and transitions; the last step shows the features as tiles
* While changing the file icon size, empty places in the new size fill two rows of the shelf, also when it is empty
* Images from the web no longer disappear right after dropping them
* Nothing scrolls under the page title in Settings any more
* Keyboard: the shortcuts in the shelf are collapsed
* Settings are slightly more transparent

## 1.30.0-beta.4
* Right-click menus of the shelf are drawn by BarDrop itself: the highlight follows the pointer without delay and they look like the lists in Settings
* Convert is a submenu again that opens next to the menu while the menu stays visible
* No extra tap when dropping a file; the click of the trackpad is enough
* Lists in Settings stay in place while scrolling, and clicking the same button again closes them
* Settings and the introduction are slightly more transparent
* While changing the file icon size, the app icon lies in the shelf as a sample
* The introduction goes step by step in one column without a sidebar

## 1.30.0-beta.3
* The introduction is built like Settings: the steps in a sidebar that tick themselves off, the content in the same cards, buttons and switches; language and opening at login right on the first page, everything else BarDrop can do on the last
* Choices in Settings open a list in the style of the cards instead of a system menu; the same goes for adding actions and apps
* Actions → Icon size: a slider for the icons in the action bar
* Both icon sizes change live in the shelf at the edge
* For copies, Show in Finder and Copy Path use the original file
* Convert opens its own menu in the same place instead of a submenu, so it looks like the right-click menu
* No more double tap on switches and modifier keys in Settings; the click on the trackpad is the one tap
* Right-click menus of the shelf make BarDrop active first, so the highlight follows the pointer

## 1.30.0-beta.2
* New introduction: a calmer welcome, the three steps to try, and one page with everything else BarDrop can do
* Short choices sit right in the row as a switch (for example edge, sort order, title, animation, language); longer lists still open a menu
* Keyboard: the shortcuts you need all the time first, the rest under “More”, with keys shown as small key caps; a light tap when you change the shortcut
* Two rows are always available; the switch is gone, an empty bottom row simply isn’t shown
* Web images keep their original format when “Save web images as PNG or JPEG” is off
* Items that are still loading show up right away as a tile with a spinner
* Show in Finder shows the original file, also when the shelf holds a copy
* Changing the icon size shows the open shelf live at the edge
* Introduction: fixed a stray comma in the “get it back” step

## 1.30.0-beta.1
* Appearance → Size → Icon size: icons and previews in the shelf from 40 to 96 pt, now 64 pt by default (was 56)
* With the larger hit area, a dragged file opens the shelf from a little farther away
* Right-click menus no longer lose the highlight: the shelf pauses its checks while a menu is open

## 1.29.0
Everything since 1.28.0:
* Updates install by themselves in the background once BarDrop hasn’t been used for 15 minutes; Beta versions can be turned on in Settings → About BarDrop
* Convert with a right-click on an item or a selection: images, PDF pages, text documents, audio and video, using only what macOS includes
* Dragging out works like in the Finder for every item, with the name highlighted the same way and previews also for files just added
* Built for macOS 26: window buttons, menus and alerts in the current system style; the Settings window has all three window buttons
* Right-click menus without icons, as Apple does it again since macOS 27; only Share and Settings keep theirs
* Holding ⌫ removes only one item
* Without names under the actions, their icons are larger
* Settings: software update in its own row, fewer info buttons, all texts reviewed in English and German

## 1.29.0-beta.4
* Right-click menus without icons, as Apple does it again since macOS 27; only Share and Settings keep theirs
* Dragging out: the name is highlighted like in the Finder, tight around the text with only slightly rounded corners

## 1.29.0-beta.3
* Dragging out works like in the Finder for every item: files BarDrop stored itself (copies, web images, converted files) now go out as a fresh copy of the file instead of a file promise, so the Finder and other apps show the usual drag and drop
* About BarDrop: software update in its own row, the version reads “1.29.0 Beta 3” and is never cut off

## 1.29.0-beta.2
* Built with Xcode 26 on macOS 26: window buttons, menus and alerts in the current system style (Liquid Glass) on macOS 26 and later
* Settings window with all three window buttons, like other apps
* Dragging items out looks like in the Finder: the name in a capsule in your accent color, and images just converted show their preview instead of a plain icon

## 1.29.0-beta.1
* Updates install by themselves in the background once BarDrop hasn’t been used for 15 minutes; afterwards it just keeps running, without a message
* Holding ⌫ removes only one item; press again for the next
* Version numbers: betas are called like the version they lead to, for example 1.29.0-beta.1
* Fewer info buttons: Where, larger hit area, full screen, excluded apps and screenshots explain themselves
* Clearer texts for automatic updates and beta versions

## 1.28.1
* Beta channel: Settings → About BarDrop → Beta versions. New versions appear as betas first; regular versions summarize everything since the last one
* Convert moved to the right-click menu of an item or a selection (several images can be combined into one PDF); it’s no longer an action in the bar
* Names under the actions are back to their previous size

## 1.28.0
* New action “Convert” (add it under Actions): drop files on it and pick a format. Uses only what macOS includes: images to PNG, JPEG, HEIC, TIFF, GIF, BMP (and any other format macOS can write), resize to 2048, 1024 or 512 px, images into one PDF, PDF pages as PNG or JPEG, text documents (TXT, RTF, HTML, DOCX, DOC, ODT), audio (M4A, Apple Lossless, WAV, AIFF, CAF) and video (MP4, MOV, HEVC, 1080p, 720p, audio only). The result appears in the shelf, the original stays
* Share and Convert tiles look like app icons, with a soft shine and shadow
* Actions → Show names: hide the names under the actions
* Names under the actions get a bit smaller before they’re shortened

## 1.27.0
* Pinning in the shelf looks like the other actions: the real icon of the folder or app appears faded with a small plus and comes to full strength when you’re over it
* An action you drag out of the shelf fades at its place, like an icon dragged out of the Dock
* Settings: no reset buttons on single sections anymore; resetting everything stays under General

## 1.26.1
* New installations start with the light outline on again; existing settings stay as they are
* Introduction matches the app: the step for getting the image back follows “Open shelf” (instantly, after a wait, or on click), the tips mention Trash and pinning instead of Mail, automatic stacks, and that opening BarDrop again shows Settings

## 1.26.0
* After removing with ⌫ the next item is selected (at the end the one before), so you can keep going
* ⌘X cuts like Ctrl+X on Windows: the items go to the clipboard and out of the shelf; ⌘Z brings them back
* “Path copied” now also appears in English

## 1.25.2
* Open in full screen: BarDrop now asks macOS whether a display shows a full screen space, instead of guessing from window sizes. A window that merely fills the screen no longer counts as full screen

## 1.25.1
* Open in full screen: also recognized on displays with a notch, where full screen apps leave the strip next to the camera free; checked again a little later after switching to full screen
* A light tap when you bring an item you dragged out back to the edge and the shelf opens again
* No more double tap when dropping: if the file reached the shelf just before, the drop tap is skipped
* With “Always store a copy”, a tile no longer fades in again when the copy is done
* Dragging an action out removes it as soon as it’s outside the black shelf, not only outside its shadow
* Older delay values snap to the nearest choice under “Open shelf”

## 1.25.0
* The fade above the action bar starts and ends softly, so no line is visible where it turns opaque; it still reaches only 24 points into the items
* Dropped files no longer flash a white blank document first: tiles show the icon of the file type and wait a moment for the preview
* Settings open on the display where the shelf is
* New defaults: actions AirDrop, Downloads and Trash; always store a copy; larger hit area; pin by dragging; no outline; shelf height 380 pt; strip 7 × 80 pt with 65 % edge curve. Settings you changed yourself stay as they are

## 1.24.1
* Menus under a button open upward when there isn’t enough room below, instead of running into the screen edge
* Not in these apps: list and “Add App” look like the action list, with “No apps” while it’s empty
* “Open shelf” instead of “Open” inside the Opening tab

## 1.24.0
* Open in full screen (Settings → Opening): when off, moving to the edge doesn’t open the shelf while an app is in full screen on that display; dragging files and the shortcut still work

## 1.23.1
* Action bar fully opaque again; items only fade out above it
* Keyboard: the three most used shortcuts shown, all others behind “All shortcuts”
* Not in these apps: the menu suggests only the eight most recently opened apps

## 1.23.0
* Not in these apps (Settings → Opening): while one of the listed apps is in front, moving to the edge doesn’t open the shelf; dragging files and the shortcut still work

## 1.22.0
* Items run on under the action bar and fade softly behind it instead of being cut off; the last row can be scrolled fully above the bar
* Opening: one choice “Open” (instantly, after 1 to 5 seconds, or only on click) instead of three settings; with a wait, clicking the strip always opens right away
* Clearer names: “Spot along the edge” for the position slider, “Title” (BarDrop or Shelf) instead of a switch
* Settings sorted: “Add automatically” for new screenshots under Items, “In the shelf” for pinning under Actions

## 1.21.2
* The bottom edge of the item grid now fades out completely, without a visible edge at the end

## 1.21.1
* Items fade out softly at the bottom edge above the action bar instead of being cut off

## 1.21.0
* With “Always store a copy”, files from the Finder show up right away and are copied in the background; once a copy is done it takes the original’s place
* With “Show name” off the shelf is titled “Shelf”
* Reordering actions: the dragged action stays inside the list and above everything else

## 1.20.1
* The shelf is titled “BarDrop”; the name can be hidden (Settings → Appearance → Show name)
* Dropped items show up right away instead of sometimes only after reopening the shelf: new tiles no longer fade in

## 1.20.0
* New screenshots can go straight into the shelf (Settings → Items → Add new screenshots)
* Pin by dragging: drop a folder or app on “Pin” at the end of the action bar, drag an action out of the shelf to remove it (Settings → Actions)
* Reordering actions: the bottom row stays in place while you drag, so its places are easy to hit
* After an update BarDrop restarts reliably: the new version is opened by macOS itself and waits until the old one has quit

## 1.19.2
* Trash action shows the system trash icon
* Share action in blue, matching AirDrop, folders and Mail

## 1.19.1
* Sliders snap exactly onto the dots below them, also for shelf height and strip length

## 1.19.0
* Settings sorted by what you want to do: Opening (where and when the shelf opens) and Appearance (size, strip, style) instead of Shelf, with opening options moved out of General
* Introduction: dots show your progress; the settings tip shows the real tabs with their icons
* Trash as an optional quick action (add it under Actions)
* Changed your mind while dragging something out? Bring it back to the edge, the shelf opens again and you can put it back
* Settings window only moves by its title bar, so dragging actions or sliders no longer drags the whole window
* Safer around drag and drop: BarDrop only watches drags of other apps, catches fast drops only right where the shelf is, and closes its trackpad connections cleanly

## 1.18.1
* After launch the strip shows briefly at the edge, so you can see BarDrop is running
* The introduction only counts as seen once it’s closed; if anything goes wrong it appears again on the next launch
* Settings: fewer info buttons, only where a label alone isn’t enough
* Actions: “Add Action” as the last row of the list; remove an action with the button that appears when you hover over it

## 1.18.0
* Introduction: you now drag the image from the shelf back into the window
* Dropped items appear right away, also web images that arrive after a download
* ⌘,, ⌘W and ⌘Q work in Settings and the introduction
* Undo: restored items no longer get removed again by automatic cleanup; a beep when there is nothing left to restore
* Function keys are shown correctly as shortcut
* What’s new shows English notes for older versions too
* Updates are only installed with a verified checksum
* Faster with files on network drives; icons refresh when the shelf opens

## 1.17.1
* Two-row action bar: each row is centered and uses the full width instead of being squeezed to the left
* The update button just says “Update” so it fits next to the icon
* Introduction: headings no longer get cut off
* All texts reviewed in English and German; clearer wording for the delay (“None”, “1 second”), the drag hint (“Show strip right away”), resetting and updating
* Language has its own card in General

## 1.17.0
* Reordering actions rebuilt: the order stays fixed while you drag, every row has a computed place, the dragged row follows the pointer and the others glide aside; saved only when you let go
* Two rows: drag an action into the top or bottom row, up to five per row; a full row passes its last action on
* The shelf redraws right away when content arrives late (web images, large files, iCloud) instead of only after reopening
* Longer introduction: three tips on actions, keeping things tidy and settings, plus a language switch on the first page
* New preview animation in the README: three captioned steps, seamless loop

## 1.16.0
* English by default, German selectable in Settings → General; all texts reviewed and clarified in both languages
* Repository in English, German README available
* Reordering actions: the row follows the pointer and snaps into each slot with a light tap on the trackpad
* Optional larger hit area around the strip and handle
* Files flung quickly at the screen edge are caught reliably, even when released just next to the shelf
* Action bar in two rows of up to five actions each (optional)
* What’s new shows the release notes in the selected language

## 1.15.1
* Darker, slightly translucent settings with colors taken from Klack
* Sliders with tick marks; they snap in steps and give a light tap on the trackpad
* Pop-up menus always open at their value instead of at the pointer; ⌃⌄ in a circle, slider values in a capsule
* ⌘, opens Settings and ⌘Q quits BarDrop from the open shelf too

## 1.15.0
* Settings rebuilt one to one in the style of Klack: custom cards, rows, pill switches, plain pop-up menus, sliders, keys and sidebar, independent of the macOS version

## 1.14.0
* Actions can be reordered by dragging again
* No menu bar icon anymore; the screen edge always opens the shelf
* Adjusting width and height shows the open shelf at the edge
* Reset: put all settings back to their defaults after a confirmation
* Settings reorganized: Startup, Opening, Feedback; outline and animation under Shelf → Appearance
* About BarDrop: updates at the top, credits collapsible and complete, introduction at the bottom
* Smoother opening animation: item icons are cached, the shadow uses a single layer

## 1.13.2
* Settings: no light strip at the bottom of the window anymore

## 1.13.1
* The shadow of the open shelf fades out softly instead of being cut off at the window edge
* About BarDrop: an info button next to the version shows the changes of recent versions straight from GitHub

## 1.13.0
* Settings closer to Klack: one translucent background, short headings, explanations behind an info button, sliders show their value
* Light outline as its own switch under Shelf → Appearance
* With a delay of one second or more, clicking the strip opens the shelf right away (can be turned off)

## 1.12.1
* Dropped items appear right away, not only when the shelf closes
* GPL-3.0 license, third-party notices, new README, preview shows the current look

## 1.12.0
* Thin light outline around the strip and shelf, visible on dark backgrounds (can be turned off)
* Adjustable delay before opening: instantly or after 1 to 5 seconds
* Calmer introduction: same layout on every page, “Step 1 of 3”, large button at the bottom
* Removed code that was no longer needed (arrow in the handle, dropping onto tiles)

## 1.11.0
* New settings with a sidebar and colored icons, inspired by Klack
* Freely choosable shortcut: click modifier keys, record a key
* About BarDrop with updates, introduction and credits
* Outer corners of the thin strip as round as on the thick one; transitions at the screen edge as before

## 1.10.0
* Updates inside the app: checks GitHub, verifies the checksum, replaces BarDrop and restarts
* DMG installer window with background and an arrow to the Applications folder
* Introduction in macOS style (light and dark appearance, system buttons); the sample image no longer snaps back
* Thumbnails with rounded corners like in the Finder
* Thin strip with corners as soft as the thick one

## 1.9.3
* Introduction: dragging the sample image now reliably opens the shelf
* Selection in the open shelf always uses the accent color instead of gray; focus on opening is more reliable

## 1.9.2
* The message after removing has no button anymore, only text (⌘Z still undoes)
* Thumbnails of freshly dropped files appear right away without reopening the shelf

## 1.9.1
* Dragging items onto a tile no longer creates a stack; stacks are created via selection and “Group as Stack”
* Position “Follows pointer, middle half” in addition to “middle third”
* Arrow in the handle removed
* The selected action in Settings is clearly highlighted

## 1.9.0
* Introduction on first launch: drop an image, get it back, press the shortcut; each step notices by itself when it’s done
* Removing can be undone with ⌘Z and redone with ⇧⌘Z, with a short “Undo” message in the shelf
* Short feedback when copying, keyboard shortcuts visible in the context menu
* New setting “Sort order”: newest or oldest first
* Settings made consistent: explanations left-aligned, all sliders alike, ⌘Z in the keyboard overview
* New defaults for new installations
* Menu bar icon only on request (Settings → General), Quit also via right-click in the shelf
* Action bar without gray background, menus without ellipses
* The selection rectangle stays inside the shelf
* The open shelf has keyboard focus right away (⌘A, arrow keys and more) and gives it back when closing

## 1.8.6
* “Follows pointer, middle third only”: the shelf only appears when the pointer is really within the third, and always sits centered at the pointer instead of offset at the edge of the area
* Multiple displays: at the edge between two displays the shelf no longer opens when you move a file or the pointer across

## 1.8.5
* Files from external drives stay in the shelf while the drive is disconnected (grayed out) and are back to normal once it’s connected
* Links to downloads (ZIP, videos, disk images) are saved as links right away without downloading the whole file
* Folders in the home folder named “tmp”, “Caches” or “TemporaryItems” count as your own folders: files from them are linked instead of copied
* A shortcut that’s already taken is reported in the log

## 1.8.4
* Strip with a straight front, small round corners and a short curve into the edge; “Edge curve” slider

## 1.8.3
* The shelf reliably appears on the display with the pointer (stable display ID, edge tolerance, immediate switch)
* Shortcut: closes when switching to another display
* Small temporary files from other drives are saved right away

## 1.8.2
* “Ends” slider: the strip can be anything from round to completely flat, never pointed

## 1.8.1
* Softly tapering ends on the strip, without hard corners

## 1.8.0
* Flat, long strip close to the edge that bulges out elastically like the iPhone volume indicator; only one preliminary stage left
* Handle with arrow only for “On click”
* A light tap as soon as a dragged file reaches the shelf and when dropping; no more double vibration

## 1.7.0
* Dragging out via file promises (based on perch), fresh copy for other apps, text and links in their own format, moving allowed
* Own files are only deleted after the copy has finished and are restored on errors
* Bookmarks instead of paths, damaged entries skipped individually, copying in the background, iCloud Drive
* The timer rests when idle, detection via system events; Quick Look on the shelf’s display; “Reduce motion”
* Settings made consistent, confirmation before “Remove All”, log in the Console app, edge logic tested

## 1.6.0
* Fixed error −8060 when dragging web images onward (files are rewritten cleanly)
* Follows pointer: centered on the side of the screen while dragging
* Shape of the first strip adjustable (thickness, length, roundness)
* Actions tab in the unified style

## 1.5.1
* Setting “Always store a copy” (off by default)

## 1.5.0
* Taking in web content rebuilt, with automated tests on macOS
* Selection, selection rectangle and keyboard commands in the open stack
* Tiles only become a stack target after hovering for a moment
* Drag image with icon and file name like in the Finder
* Haptics for the first strip, arrow can be turned off, settings combined, “While dragging” with three levels

## 1.4.2
* Idle mode saves energy (fewer checks when hidden and the pointer is far away)
* README: explanation of the macOS warning on first launch

## 1.4.1
* Fixed error −43 with web images (temporary files are copied)
* Follows pointer: no dragging along when closing

## 1.4.0
* Haptics also work in the background, settings window without jumping and flickering
* Stacks as their own view with Back, adjustable stack size, drop items onto tiles
* Animation strength, open on click, follows pointer within the middle third
* Items disappear after quick actions (can be turned off), Keyboard tab

## 1.3.1
* The shelf stays round while disappearing
* Preview animation shows dropping and dragging out into another app, looping seamlessly

## 1.3.0
* Fixed dragging out into other apps, more reliable dropping
* Follows pointer, centered on it
* Multiple displays: no jumping, never visible twice; “Available on” setting
* Remove automatically after 1, 2, 5, 10 or 24 hours
* Longer strip while dragging, count without animation, settings tidied up

## 1.2.0
* Group stacks, expand and collapse them, take files out
* Automatic removal, follows pointer, “Copy Path” (⌥⌘C)
* Web images are saved in a compatible format (WebP, AVIF, HEIC → PNG/JPEG)
* Settings with tabs, Finder-style selection, right-click on empty areas

## 1.1.0
* Action bar with AirDrop, Mail, Messages, folders and apps
* Multiple selection with ⌘/⇧-click and selection rectangle, keyboard shortcuts
* Rounder preliminary stages, Share menu on the file

## 1.0.0
* First version: an edge shelf that appears in three stages while dragging
