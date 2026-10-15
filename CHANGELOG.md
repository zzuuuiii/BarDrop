# Changelog

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
