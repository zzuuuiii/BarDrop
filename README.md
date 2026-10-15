<p align="center">
  <img src="Resources/AppIcon.png" width="112" alt="BarDrop">
</p>

<h1 align="center">BarDrop</h1>

<p align="center">
  An invisible shelf at the edge of your screen.<br>
  <sub><b>English</b> · <a href="README.de.md">Deutsch</a></sub>
</p>

<p align="center">
  <a href="https://github.com/zzuuuiii/BarDrop/releases/latest/download/BarDrop.dmg"><b>Download</b></a>
  &nbsp;·&nbsp;
  <sub>macOS 14 or later · Apple Silicon & Intel · free and open source</sub>
</p>

<p align="center">
  <img src="docs/preview.gif" width="660" alt="A file is dragged to the screen edge, the shelf opens and takes it; later it is dragged back out into an email">
</p>

## How it works

1. **Drag a file to the edge** of your screen. The shelf opens and keeps it.
2. **Switch to any app.**
3. **Move the pointer to the edge** and drag the file back out.

Works with files, folders, images from the web, links and text. A short introduction on first launch shows each step.

## Install

[Download BarDrop.dmg](https://github.com/zzuuuiii/BarDrop/releases/latest/download/BarDrop.dmg), open it and drag BarDrop into Applications. Updates come through the app.

<details>
<summary><sub>macOS says it can’t check BarDrop?</sub></summary>
<br>

That appears for every app that isn’t notarized through Apple’s paid developer program; nothing harmful was found. The DMG is built by [GitHub Actions](https://github.com/zzuuuiii/BarDrop/actions) straight from this code. Allow it once under **System Settings → Privacy & Security → Open Anyway**.

</details>

<details>
<summary><sub>Features</sub></summary>
<br>

* Left or right edge, at a fixed height or wherever the pointer reaches the edge
* Opens right away, after a short delay, on click or with a shortcut (`⌃⌥B`)
* Action bar for AirDrop, Mail, Messages, any folder or app, in one or two rows
* Stacks, Quick Look, selection like in the Finder, `⌘Z` to undo
* Remembers moved and renamed files, loads iCloud files when needed
* Cleans up after a set time if you like, survives restarts
* English and German, no menu bar icon, practically no energy use when idle

</details>

<details>
<summary><sub>Keyboard</sub></summary>
<br>

| Key | Action |
|---|---|
| `⌃⌥B` | Show or hide the shelf (changeable) |
| Space, `⌘Y` | Quick Look |
| `↩`, `⌘O` | Open |
| `⌘R` | Show in Finder |
| `⌘A`, `⌘C`, `⌥⌘C`, `⌘V` | Select all, copy, copy path, paste |
| `⌫`, `⌘Z`, `⇧⌘Z` | Remove, undo, redo |
| `⌘,`, `⌘Q` | Settings, quit |
| `esc` | Clear selection, leave stack, close |

</details>

<details>
<summary><sub>Privacy</sub></summary>
<br>

BarDrop collects no data. The shelf lives only on your Mac in `~/Library/Application Support/BarDrop`. The only connection is the update check on GitHub, which you can turn off.

</details>

<details>
<summary><sub>Build it yourself</sub></summary>
<br>

```bash
git clone https://github.com/zzuuuiii/BarDrop.git
cd BarDrop
./scripts/build_app.sh   # build/BarDrop.app and build/BarDrop.dmg
swift test
```

Requires macOS 14 and Xcode 15 or later. Every push to `main` builds, tests and releases the version in [`VERSION`](VERSION).

</details>

## Thanks

Inspired by [Alcove](https://tryalcove.com) and [Klack](https://tryklack.com), with code from [boring.notch](https://github.com/TheBoredTeam/boring.notch) and [perch](https://github.com/hausfold/perch). Details in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Not affiliated with any of these projects.

<sub>[Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · © 2026 zzuuuiii · [GPL-3.0](LICENSE)</sub>
