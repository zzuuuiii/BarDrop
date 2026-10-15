# Changelog

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
* Selection in the open shelf always uses the accent color instead of grey; focus on opening is more reliable

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
* Action bar without grey background, menus without ellipses
* The selection rectangle stays inside the shelf
* The open shelf has keyboard focus right away (⌘A, arrow keys and more) and gives it back when closing

## 1.8.6
* “Follows pointer, middle third only”: the shelf only appears when the pointer is really within the third, and always sits centered at the pointer instead of offset at the edge of the area
* Multiple displays: at the edge between two displays the shelf no longer opens when you move a file or the pointer across

## 1.8.5
* Files from external drives stay in the shelf while the drive is disconnected (greyed out) and are back to normal once it’s connected
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
