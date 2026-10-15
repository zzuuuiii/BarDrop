<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="BarDrop">
</p>

<h1 align="center">BarDrop</h1>

<p align="center">
  An invisible shelf at the edge of your screen.<br>
  Drop a file in, drag it back out later.
</p>

<p align="center">
  <b>English</b> · <a href="docs/README.de.md">Deutsch</a>
</p>

<p align="center">
  <a href="https://github.com/zzuuuiii/BarDrop/releases/latest/download/BarDrop.dmg"><b>Download</b></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/zzuuuiii/BarDrop/releases">All versions</a>
  &nbsp;·&nbsp;
  <a href="CHANGELOG.md">Changelog</a>
</p>

<p align="center">
  <a href="https://github.com/zzuuuiii/BarDrop/releases/latest"><img src="https://img.shields.io/github/v/release/zzuuuiii/BarDrop?label=Version&color=111111" alt="Version"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111111" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%26%20Intel-111111" alt="Apple Silicon and Intel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-111111" alt="License GPL-3.0"></a>
</p>

<p align="center">
  <img src="docs/preview.gif" width="640" alt="BarDrop grows out of the screen edge, takes a file and hands it to another app">
</p>

---

## How it works

1. **Drag a file.** A thin black strip curves out of the screen edge.
2. **Hold it there.** The shelf opens with a light tap on the trackpad. Let go, done.
3. **Later.** Move the pointer to the edge, the shelf opens, drag the file out into any app.

Images from the browser, links and text work just like files. On first launch a short introduction walks you through each step.

## Installation

1. [**Download BarDrop.dmg**](https://github.com/zzuuuiii/BarDrop/releases/latest/download/BarDrop.dmg) and open it.
2. Drag BarDrop onto the **Applications** folder in the window.
3. Open BarDrop from Applications.

> [!NOTE]
> **A warning on first launch?** macOS shows this for every app that isn’t notarized through Apple’s paid developer program. It doesn’t mean anything harmful was found. The DMG is built by [GitHub Actions](https://github.com/zzuuuiii/BarDrop/actions) straight from this source code.
>
> To allow it once: close the message, then go to **System Settings → Privacy & Security → Open Anyway**.

After that, BarDrop installs new versions itself when you agree (can be turned off in Settings → About BarDrop).

## Features

**Shelf**
* Left or right edge, at a fixed height or wherever the pointer reaches the edge (whole edge, middle half or middle third)
* Opens instantly or after 1 to 5 seconds at the edge, on click or with a keyboard shortcut; a click on the strip skips the wait
* Optional larger hit area for when you just miss the strip
* Files flung quickly at the edge are still caught
* Thin light outline so it stays visible on dark backgrounds
* On all displays, or only the built-in or external ones
* Uses practically no energy while idle

**Items**
* Files, folders, images from the web (WebP, AVIF and HEIC can be saved as PNG or JPEG), links and text
* Newest or oldest first, stacks, selection like in the Finder
* Removed something by accident? `⌘Z` brings it back
* Moved or renamed files stay in the shelf, iCloud files are downloaded when needed, files from disconnected drives stay greyed out
* Contents survive a restart and can be cleaned up automatically after 1 to 24 hours

**Action bar**
* AirDrop, Mail, Messages, Share, any folder or app
* Drag items onto it, or select them and click
* One row with up to six actions or two rows with up to ten

**Settings**
* English or German
* No menu bar icon: right-click the shelf for Settings and Quit

## Keyboard

| Key | Action |
|---|---|
| `⌃⌥B` | Show or hide the shelf anywhere (change it in Settings → Keyboard) |
| Space, `⌘Y` | Quick Look |
| `↩`, `⌘O` | Open |
| `⌘R` | Show in Finder |
| `⌘A` | Select all |
| `⌘C`, `⌥⌘C` | Copy, copy path |
| `⌘V` | Paste from clipboard |
| `⌫` | Remove selection |
| `⌘Z`, `⇧⌘Z` | Undo, redo |
| `⌘,` | Settings |
| Arrow keys | Move selection, extend with `⇧` |
| `esc` | Clear selection, leave stack, then close |

## Privacy

BarDrop collects no data and sends nothing about you. The shelf lives only on your Mac in `~/Library/Application Support/BarDrop`. The only internet connection is the update check on GitHub, which you can turn off. Images and links from the web are only downloaded when you drag them into the shelf yourself.

## Build it yourself

```bash
git clone https://github.com/zzuuuiii/BarDrop.git
cd BarDrop
./scripts/build_app.sh        # creates build/BarDrop.app and build/BarDrop.dmg
swift test                    # automated tests
```

Requires macOS 14 and Xcode 15 or later. Every push to `main` builds the app, runs the tests and publishes the DMG as a release of the version in [`VERSION`](Resources/VERSION).

<details>
<summary><b>Project layout</b></summary>

| File | Purpose |
|---|---|
| `EdgeController.swift`, `EdgeLogic.swift` | Detects the pointer and drags, decides which stage to show |
| `ShelfPanel.swift`, `ShelfViews.swift`, `EdgeBlobShape.swift` | Window, interface and shape of the shelf |
| `ShelfStore.swift` | Contents, storage, undo |
| `ContentImporter.swift`, `ImageNormalizer.swift`, `CloudFiles.swift`, `FileSanitizer.swift` | Taking in files, web images, links and text |
| `DragExport.swift`, `DragSource.swift` | Dragging out |
| `ShelfActions.swift`, `ActionBar.swift`, `QuickActions.swift` | Selection, menus, action bar |
| `SettingsWindow.swift`, `SettingsView.swift`, `SettingsStyle.swift`, `AppSettings.swift` | Settings |
| `L10n.swift` | English and German texts |
| `Onboarding.swift` | Introduction on first launch |
| `Updater.swift`, `ReleaseNotes.swift` | Updates and release notes from GitHub |
| `Tests/` | Automated tests |
| `scripts/` | Build, DMG, app icon, preview |

</details>

## Thanks

BarDrop wouldn’t be what it is without these projects:

* [**Alcove**](https://tryalcove.com): model for the shape and motion of the black shelf growing out of the screen edge.
* [**Klack**](https://tryklack.com): model for the layout and design of the settings.
* [**boring.notch**](https://github.com/TheBoredTeam/boring.notch): parts of the code, especially taking in images from the web.
* [**perch**](https://github.com/hausfold/perch): parts of the code that improved the app, for example dragging out and iCloud files.

License details for third-party code are in [THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md). BarDrop is an independent project and not affiliated with any of these projects.

## Contributing

Bugs and ideas are welcome as [issues](https://github.com/zzuuuiii/BarDrop/issues/new/choose); please report security issues privately (see [SECURITY.md](.github/SECURITY.md)). How contributions work is described in [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## License

© 2026 zzuuuiii. BarDrop is free software under the [GNU General Public License v3.0](LICENSE). You may use, modify and share it, as long as anything you share is also under the GPL-3.0 and comes with its source code. BarDrop is provided without warranty.
