# MagicPlus

[![CI](https://github.com/emreramazanoglu72/MagicPlus/actions/workflows/ci.yml/badge.svg)](https://github.com/emreramazanoglu72/MagicPlus/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey)

A macOS menu bar utility that combines menu bar management, window tiling, clipboard history,
a Dynamic Island style notch panel, a download queue, per-app volume, battery care and system
monitoring in one place. No account, no telemetry; the only network traffic MagicPlus starts
on its own is the update check — the rest is the downloads you ask it for.

Free and open source under the [MIT license](LICENSE).

> Internally the Xcode target and bundle identifier keep the original `tabmenu` name, so
> permissions granted and data stored before the rename keep working.

## Building it yourself

```bash
git clone https://github.com/emreramazanoglu72/MagicPlus.git
cd MagicPlus
open tabmenu.xcodeproj
```

Xcode resolves [Sparkle](https://github.com/sparkle-project/Sparkle) on first open, and that
is the only dependency. Building and running the tests needs **no Apple Developer account** —
the app is signed ad-hoc.

To sign with your own team (only needed to distribute a build), copy
`Config/Local.example.xcconfig` to `Config/Local.xcconfig` and put your Team ID in it. That
file is gitignored, so no one's team ID ever ends up in a commit.

From the command line:

```bash
xcodebuild -project tabmenu.xcodeproj -scheme tabmenu -destination 'platform=macOS' build
xcodebuild test -project tabmenu.xcodeproj -scheme tabmenu -destination 'platform=macOS'
```

## Modules

Every part of the app can be switched off from Settings → Modules, and switching one off releases
what it was holding rather than merely hiding it: its samplers stop, its observers come off, its
menu bar items go back, and — the part that makes the switch mean something — its global keyboard
shortcuts are handed back to the system. Tabs for a module that is off disappear from the popover
and the island. One place decides all of it, so a switch here and the same switch in a feature's
own tab cannot disagree.

## Features

### Window Manager
- 11 placement commands (halves, quarters, thirds, maximize, center, restore)
- Repeating a shortcut cycles through variants: half → two-thirds → third
- **Drag to a screen edge** to snap, with the target zone previewed before you let go.
  A drag only counts once the window has actually moved, so dragging text or a file to the
  edge never triggers it
- **Rules**: pick an app in Settings and its first window is placed automatically whenever
  it opens
- **Workspace layouts**: save the position of every open window and bring the whole
  arrangement back later. The first three layouts get keyboard shortcuts. Restoring matches
  windows by app and title, falling back to any window of that app, and reports what it
  could not find
- Multi-display aware, works on vertical monitors, respects Dock and menu bar
- Configurable gap between tiled windows
- Original frame is remembered so any window can be restored

### Menu Bar Manager
The bar is cut into three sections by two status items the app owns: a chevron, and a divider
that grows wide enough to push everything on its left out of the bar. Nothing is moved,
rewritten or destroyed — quitting MagicPlus puts every item straight back.

- **⌘-drag an item across the divider** to hide it. Everything to the right of the divider
  stays on show, which is the same rule the menu bar itself lays out by
- **Always-hidden section**: an optional second divider for the items that should only ever
  be reached deliberately (⌥-click the chevron)
- Reveal from the chevron, from `⌃⌥H`, or by hovering the menu bar
- **Folds away again** on your terms: never, when the pointer leaves the bar, when another
  app comes to the front, or after a delay — and never while a menu opened from a revealed
  item is still on screen
- **Hidden items strip**: an optional panel under the menu bar carrying the hidden items, for
  a notched display with no room left to fold them back into. Clicking one clicks the real
  item, wherever it currently is
- **Search** (`⌃⌥S`): a Spotlight-style panel over every item in the bar, hidden ones
  included, that clicks the one you pick
- **Appearance**: an optional solid or gradient tint over the bar with a bottom border,
  drawn under the status items so icons and menus stay legible, and dropped in full screen
- **Spacing**: the system-wide gap between items and the padding around their highlight,
  adjustable and resettable. Both reach an app the next time it launches
- Item artwork is captured with Screen Recording and cached while items are on screen, since
  a hidden item can no longer be captured; without the permission the strip and the search
  panel fall back to application icons

### Notch Panel
A Dynamic-Island-style surface. At rest it is *exactly* the hardware notch — same width,
same height, pure black — so there is nothing to see. Things that happen expand it briefly
and it collapses on its own; hovering opens the full panel.

| Stage | Trigger | Shows |
| --- | --- | --- |
| Idle | Nothing happening | The bare notch |
| Activity | Track change, volume key, meeting due, files dropped, power plugged in | A capsule flanking the notch, auto-hiding after 1.4–5s depending on what it is |
| Expanded | Pointer on the notch | Full panel below the notch |

The silhouette is one animated shape: its top corners flare into concave shoulders as it
widens, so the island appears to stretch out of the hardware rather than appear on top of it.
Artwork carries between stages with a matched-geometry transition.

Everything drawn inside it comes from one file, `NotchDesign.swift`: a 4pt spacing grid, four
text sizes, four surface fills, three ink levels, five radii and a semantic colour set, plus
the controls built from them. The island is the one surface here that cannot borrow the
system's materials — it has to pass for hardware, on pure black, at small sizes — so it is
also the one that most needs its own scale rather than a value improvised per view. Every
pane is the same height, so the panel never resizes under the pointer, and all thirteen
activities render through a single presentation — glyph, headline, detail, optional meter or
badge — so a glance lands in the same place whatever just happened.

Activities have priorities, so a meeting about to start is never buried under a track change,
and repeated volume presses replace one another instead of queueing.

- **Volume**: pressing the hardware volume keys shows the level in the notch, read through
  CoreAudio so it keeps up with the keystroke
- **Screenshots** land on the shelf by themselves — take one and drag it straight where it
  belongs, without it ever cluttering the Desktop
- **Downloads**: a queue of its own, below — and anything arriving in the Downloads folder
  from elsewhere, AirDrop included, still announces itself in the island
- **File shelf**: drop files onto the panel to park them, drag them back out into any app,
  share or AirDrop the whole set, reveal in Finder. The shelf survives restarts and drops
  entries whose files have moved
- **Playback**: transport controls work on whatever currently owns the media session,
  including a YouTube tab in any browser. Spotify and Apple Music additionally report track,
  artist, album and artwork. A browser is described too — the page's title and the site — but only
  once Core Audio confirms sound is coming out of it, which is also the only condition under which
  a title is read at all, and the page's own still frame stands in for cover art — sharp beside
  the title and blurred across the pane behind it. With the browser extension connected it is the
  *audible* tab that gets named — which tab is making sound is something only the browser knows —
  and without it, the tab in front is the best guess available. Shown rather than announced either
  way
- **Agenda**: the next meetings from Calendar, each with a Join button when a Zoom, Meet,
  Teams, Webex or Jitsi link can be found in the invite
- **Mirror**: live camera preview, for checking yourself before a call
- Displays without a notch get a strip in the middle of the menu bar with the same behaviour
- The panel only intercepts the pointer while open, so the menu bar stays clickable
- The waveform animates only while audio actually plays, and freezes under Reduce Motion

Playback control uses the hardware media keys rather than the private MediaRemote
framework, which returns nothing without a special entitlement on current macOS.

### Downloads
A download queue in the island, for the two cases a browser handles badly: a large file you
want to pause and pick up tomorrow, and a link you have copied but do not want to hunt for a
tab to paste into.

- **Copy a link** and the island says so in a capsule — what was found, the quality or size, and
  a chevron. Point at it and it grows into a card carrying the title, the site and how many
  formats there are, with one button to take it and one to type a different address; take the
  pointer away and it shrinks back. Clicking the capsule skips straight to the prompt. Nothing is
  downloaded until you answer, and the capsule holds three seconds unless you are looking at it.
  Dropping a link onto the island does the same, and so does *Download Link on Clipboard* in the
  menu bar item's menu
- **The prompt shows what you are about to download**: the page's own still frame behind the
  panel, blurred, with the crisp frame where an icon would be. Found without anything installed —
  a YouTube address names its own thumbnail, and every other site is asked for the `og:image` it
  already publishes
- **Type a link yourself** when detection guesses wrong — from the card, the `+` in the downloads
  pane, or the menu bar. The address is probed as you stop typing, and the name, size and folder
  fill themselves in
- **Resumes properly**: bytes go to a `.part` file beside the destination, so the offset to
  continue from is that file's size rather than a token the system may have expired. Pause,
  quit MagicPlus, come back tomorrow and the transfer continues — with a `Range` request, and
  a restart from zero if the server turns out to ignore it
- **Queue**: as many at once as you choose, the rest waiting their turn, each row showing
  size, speed and time left. Pause, resume, retry or drop any of them, and the resting island
  carries a small ring for whatever is still in flight
- **Never overwrites**: a name already taken gets numbered rather than replacing the file you
  already had, and a `Content-Disposition` of `../../.zshrc` cannot write outside the folder
  you picked
- **Interruptions are waited out**: a dropped connection or a sleeping Mac is not a failure, so the
  queue picks the transfer up again on a backoff — and immediately when the network comes back or
  the Mac wakes, rather than sitting out the rest of a wait. A 404 still fails, because that is an
  answer
- **Also in the menu bar**: a *Downloads* tab in the popover carries the same queue, so it does not
  depend on the notch panel being switched on
- **Where it goes**: the Downloads folder by default, or anywhere you like, optionally sorted
  into per-kind sub-folders
- **Browser extension** (`Extension/chromium`): the real interception. A native app cannot see a
  browser's network traffic — no API exposes it — so the extension comes to MagicPlus instead,
  over a port bound to loopback, and hands over **the cookies and referer the site expects**
  along with the URL. That context is what keeps a signed link, a members-only file or a
  referer-checked asset working outside the browser, and it is why copying a link so often ends
  in 403. Chrome's own transfer is paused first and only cancelled once MagicPlus has accepted
  it, so a failed hand-off never loses a download. Right-clicking any link, video, audio or
  image sends it over too
- **Video playing on a page**, without any helper at all: the extension watches the player's own
  requests, and by the time one is made the site's JavaScript has already signed the URL and
  solved whatever challenge went with it. Repeating that request inherits all of it — which is
  how IDM has always found video and why it never shipped an extractor either. The island offers
  the formats that turned up and `ffmpeg` joins picture and sound where the site serves them
  apart. The same trade comes with it: only a format the page actually asked for can be offered,
  so 1080p appears once the player has been set to 1080p
- **Browser tabs**: with Automation permission, MagicPlus watches the address of the front tab
  and offers media pages and file links as they appear. It reads the address bar and nothing
  else — the contents of a tab and its network traffic are not something macOS exposes to any
  app. Refuse the permission and Settings says so, with a button straight to the right pane,
  rather than leaving the feature looking broken
- **Media pages**: MagicPlus ships no site extractors and no plugin list. With
  [yt-dlp](https://github.com/yt-dlp/yt-dlp) installed, a YouTube-style page is offered with a
  quality picker and runs in the same queue with the same progress and pause behaviour.
  Without it, the prompt says exactly that and offers to install it — in a Terminal window you
  can watch, since `brew` takes minutes and occasionally asks something. `ffmpeg` matters as
  much as the helper itself: YouTube has been retiring the single-file formats, so video now
  arrives as separate video and audio streams that need joining, and asking for the old
  single-file format answers 403 on most videos
- **HLS streams (`.m3u8`) are assembled by the app itself**: a manifest is not a file but a list
  of a few hundred small ones, so there is nothing for an ordinary download to resume and the job
  used to go to `ffmpeg`. MagicPlus now reads the manifest, picks the rendition closest to the
  quality asked for, fetches segments four at a time while appending them strictly in playlist
  order, and rewrites the result as an MP4 with AVFoundation — which reads concatenated MPEG-TS
  and fragmented MP4 perfectly well, verified rather than assumed. It records how far it got
  beside the file it is writing, so quitting costs the segment in flight rather than the hour
  already spent. Live streams and encrypted manifests are refused with a sentence saying which,
  because neither can be finished
- **Joining needs nothing installed**: where a site serves picture and sound apart, both are
  fetched as ordinary downloads — resumable, exact progress, the browser's own headers — and
  joined afterwards with the muxer macOS already has, copying both streams without re-encoding.
  `ffmpeg` is only wanted for WebM, which AVFoundation cannot write, and for the per-track files
  some sites misdeclare so badly that the check catches them: rather than hand over a video at
  half speed, the join is refused and the external tool takes over if it is there
- **Cookies** (off by default): YouTube increasingly refuses a stream URL it has just issued
  unless the request carries a session — a few megabytes arrive and then every range comes back
  403. Pointing the helper at a browser you are signed into is the documented way through it,
  and it is also what gets an age-restricted page to play. It hands your session to `yt-dlp`,
  so it stays off until you pick a browser; when a download is blocked, the queue says which of
  these two settings would have fixed it instead of repeating the helper's own words

### Dock Previews
- Hovering a Dock icon shows live previews of that app's open windows
- Close (`×`) or minimise (`–`) any window straight from its preview, or quit the app
- Configurable hover delay; the panel never steals focus
- Follows the Dock to whichever screen edge it sits on

### Window Switcher
- Alt-tab style switching across every window of every app (`⌥⇥`)
- Doubles as a launcher: typing also matches installed apps that are not running, and Return
  opens them
- Two layouts: live preview grid or compact list
- Tapping the shortcut jumps straight back to the previous window; holding the modifier
  keeps the panel open so the list can be browsed, and releasing it commits the selection
- Search by window title or application name
- `⌘W` close, `⌘M` minimise, `⌘Q` quit, without leaving the switcher
- Minimised windows are listed and restored on selection

### Clipboard History
- Captures text, file URLs, and images from any app
- Spotlight-style panel (`⌘⇧V`) with instant search across content, file names, and source app
- Fully keyboard driven: `↑↓` navigate, `↩` paste, `⌘P` pin, `⌘⌫` delete, `esc` close
- **Paste-time transforms**: trim, collapse to one line, change case, pretty-print JSON,
  decode a URL. Only transforms that would actually change the entry are offered, and history
  keeps the original
- Automatically pastes into the app you were working in
- Pinned items survive history pruning
- Password managers and apps marking content as concealed are never recorded

### System Monitor
- CPU load with per-core breakdown, split by user and system time
- Memory matching Activity Monitor's model (app + wired + compressed)
- Disk capacity plus live read/write throughput via IOKit
- Network up/down throughput across all physical interfaces
- Top processes by CPU
- Thermal pressure, shown only when the Mac is actually under load. This is
  `ProcessInfo.thermalState` rather than a sensor read — it is the signal the system itself
  throttles on, and it sits next to the sensor readings below because the two answer
  different questions
- Optional CPU or memory readout in the menu bar
- Sampling cadence follows visibility: suspended when nothing is shown, 3s in the
  background, 1.5s while the popover is open

### Temperatures & Fans
Read straight from the SMC, the controller every Mac has and none of them document.

- Every temperature sensor the machine reports, grouped into CPU, GPU, battery, ambient and
  storage, with the **hottest** reading per group — averaging a dozen CPU sensors hides the
  hot core, which is the one worth seeing
- Fan speed against that fan's own minimum and maximum. Machines without fans report none
- Which keys exist differs with every Mac, so the list is discovered from the SMC's own index
  instead of a model table: a machine with sensors this project has never seen still reports
  them
- Optional CPU temperature in the menu bar, in °C or °F by locale
- Reading changes nothing and needs no privileges. Nothing here writes to the SMC — fan
  control does, and is not part of this

### Battery
- Charge level, full-charge capacity against design capacity, cycle count and battery
  temperature, from the public power-source API and the battery's own registry entry
- **Charge limit**: hold the battery at 50–100% instead of letting it fill. Keeping a lithium
  cell off full is the single thing that slows its ageing most, which is why Apple's own
  optimised charging parks at 80%
- Macs differ in how this is done and the right one is discovered, not assumed: Intel machines
  hand a ceiling to the firmware, Apple Silicon machines have charging switched off and on as
  the level crosses the target. A Mac with neither says so instead of pretending
- A 5% band below the target keeps a resting battery from switching charging on and off every
  tick, which would be worse for it than the charge being avoided
- **The limit only holds while MagicPlus runs.** Quitting restores normal charging before the
  process exits, and if the app crashes the helper's watchdog restores it within 30 seconds

### Keep Awake
- One click in the popover header (or `⌃⌥A`) stops the Mac dimming, sleeping, spinning its
  disks down, and locking itself
- Holds the same four IOKit power assertions as `caffeinate -dims`, taken directly rather
  than by spawning a helper process, so nothing can outlive the app
- Optional timer — 15 minutes through 4 hours, or until turned off — with a live countdown.
  Expiry is measured against the wall clock, so sleeping through it cannot extend a session
- The menu bar icon becomes a cup while it is on, so a forgotten session is never invisible
- "Also keep the display on" can be turned off to keep the Mac running with a dark screen
- Optionally resumes on launch, for machines that should never idle

## Meeting & Safety Tools

- **Microphone and camera indicators** live in the notch: an orange mic while any app is
  capturing audio, a green dot while any camera streams — read from the same public
  CoreAudio/CoreMediaIO signals the system's own lights use. `⌃⌥⇧M` mutes the microphone
  system-wide from anywhere; the icon turns to a red slash so a muted mic is never a mystery
- **Presentation mode** (`⌃⌥⇧P`, or the status menu): one switch that keeps the Mac awake,
  stops clipboard recording so a shared screen cannot leak history, and silences notch
  activities — except mic state, which is what the meeting is about. Everything is restored
  exactly as it was
- **Capture Text (OCR)** (`⌃⌥O`): select a region of the screen, its text lands on the
  clipboard — recognised on-device by Vision, Turkish and English. Works on video frames,
  images, and anything else that refuses to be selected
- **Rescue Windows** (`⌃⌥R`, and automatically after a display change): windows stranded
  off-screen after unplugging a monitor are pulled back where they can be grabbed
- **Search Menus** (`⌃⌥P`): a command palette over the frontmost app's entire menu bar —
  type a fragment, hit Return, the menu item runs
- **Quick Note** (`⌃⌥N`): jot a thought, `⌘↩` parks it on the shelf as a text file
- **Sensitive clipboard protection**: card numbers (Luhn-checked), API keys, private key
  blocks and JWTs are never recorded into history — they stay pasteable, just not stored
- **Threshold alerts** in the notch: battery at 10% while discharging, disk past 95% full —
  each warned once, re-armed when the condition clears
- **Output device switcher** in the notch's media pane, for when a call app hijacks audio
- **External display brightness** in the Mixer tab, over DDC/CI (IOAVService, resolved at
  runtime; degrades to hidden if unavailable). Fine for the notarized direct build; would be
  an automatic App Store rejection — one reason this app ships direct
- **Per-app volume mixer** in the notch: every app producing audio gets its own slider and
  mute. Built on macOS process taps (14.4+): the app is muted in the system mix and its
  audio replayed at your gain through a private aggregate device, so 100% simply means "no
  tap". Volumes are remembered per app and re-applied when it plays again. Requires the
  Screen & System Audio Recording permission; helper processes (Chrome's renderers) are
  grouped under their parent app

## Default shortcuts

| Command | Shortcut |
| --- | --- |
| Left / Right / Top / Bottom | `⌃⌥←` `⌃⌥→` `⌃⌥↑` `⌃⌥↓` |
| Quarters | `⌃⌥U` `⌃⌥I` `⌃⌥J` `⌃⌥K` |
| Maximize | `⌃⌥↩` |
| Center | `⌃⌥C` |
| Restore | `⌃⌥Z` |
| Workspace layouts 1–3 | `⌃⌥1` `⌃⌥2` `⌃⌥3` |
| Clipboard history | `⌘⇧V` |
| Switch windows | `⌥⇥` |
| Open tabmenu | `⌃⌥M` |
| Keep awake | `⌃⌥A` |
| Mute microphone | `⌃⌥⇧M` |
| Capture text (OCR) | `⌃⌥O` |
| Search menus | `⌃⌥P` |
| Show hidden menu bar items | `⌃⌥H` |
| Search menu bar items | `⌃⌥S` |
| Quick note | `⌃⌥N` |
| Presentation mode | `⌃⌥⇧P` |
| Rescue windows | `⌃⌥R` |

All shortcuts are rebindable in Settings → Shortcuts, which also detects conflicts with
other applications before accepting a combination.

## Requirements

On first launch a welcome window lists every permission, what each one unlocks, and what
breaks without it — with live status, so a row flips to Granted the moment you allow it in
System Settings. It is reachable again from Settings → General. Features gated on
Accessibility start themselves as soon as it is granted, with no relaunch.

- macOS 26.5 or later
- **Accessibility permission**, required to move windows, enumerate them, and paste
  automatically. Grant it in System Settings → Privacy & Security → Accessibility, or from
  the prompt in the app.
- **Screen Recording permission**, optional. Used to capture window thumbnails for the Dock
  previews and the switcher grid, and the artwork of menu bar items for the hidden items
  strip and the item search; without it all of them fall back to application icons.
- **Automation permission** for Music, Spotify and browsers, optional. Only used to read
  what is playing. Transport controls work without it.
- **Camera permission**, optional. Only used by the notch panel's Mirror tab.

The app runs unsandboxed because the Accessibility API, IOKit statistics, and process
listing are unavailable inside the App Sandbox. It is therefore distributable outside the
Mac App Store only.

### The privileged helper

The **battery charge limit** is the one feature that cannot be done from the app itself: the
SMC accepts writes from root and from nobody else. It is served by `MagicPlusHelper`, a
launchd daemon of about 200 lines that ships inside the app bundle and is registered through
`SMAppService` the first time you switch the limit on, with macOS asking you to approve it in
System Settings → General → Login Items.

What keeps that honest:

- It exposes a fixed list of requests — switch charging off, switch it on, set the firmware
  ceiling, restore, heartbeat — and no "write this key" call, so it cannot be used as a
  general-purpose root gadget
- It accepts connections only from a binary carrying this app's identifier and signed by the
  same team, checked by launchd against a code-signing requirement, and refuses to serve at
  all if it cannot establish its own team identity
- It undoes every change it has made when the app quits, when it is signalled, when it starts,
  and when MagicPlus stops sending heartbeats for 30 seconds. A crash cannot leave a Mac that
  refuses to charge
- Removing it is one button in Settings → Battery, and leaves nothing behind

Everything else in the app works without it, and it is never installed unless you ask for it.
Do not run a second charge-limiting tool alongside it: both write the same SMC keys, and the
last one to write wins.

**Registering a daemon needs a signed build.** The ad-hoc signature a plain `xcodebuild` run
produces has no team identifier, so `SMAppService` refuses it: the charge limit needs a
Developer ID build installed in `/Applications`. Sensors, fans and battery readings need none
of this and work in any build.

## Localization

English and Turkish, driven by a single String Catalog at `tabmenu/Localizable.xcstrings`.

- SwiftUI views need no special treatment: their string literals are already
  `LocalizedStringKey`, interpolation included.
- Model-layer text (`WindowAction.title`, `PermissionKind.summary`, and friends) goes through
  `String(localized:comment:)`, so AppKit menus and window titles read the same catalog.
- Counts use plural variations, which matters because English has singular/plural forms where
  Turkish has one.
- Percentages, byte sizes, durations, dates and relative times are produced by system
  formatters rather than string interpolation, so they follow the user's locale.

To add a language, add its code to `knownRegions` in the project and a `localizations` entry
per string in the catalog. Untranslated strings fall back to English rather than showing a key.

macOS lists the app under System Settings → Language & Region → Applications, so the language
can be set per app without changing the whole system.

## Tests

```
xcodebuild test -project tabmenu.xcodeproj -scheme tabmenu -destination 'platform=macOS'
```

The suite covers the logic that fails silently rather than loudly: zone geometry and the
top-left-origin coordinate space, frame comparison tolerance, clipboard fingerprinting and
history limits, meeting-link extraction from invite text, notch activity priorities and
durations, shortcut encoding and default-collision checks, workspace layout matching, the geometry that
decides which menu bar section an item belongs to, the byte layout of the SMC parameter block
and its fixed-point decoding, the charge limit's hysteresis, and the island's activity
presentation and design tokens.

`IslandSnapshotTests` renders the island's stages to PNGs so a design change can be looked at
rather than imagined. It is off unless `TEST_RUNNER_ISLAND_SNAPSHOTS=1` is set, since it
writes files and asserts nothing.

## Releasing

```
Scripts/release.sh 1.1
```

Checks that nothing ships untranslated, runs the tests, archives, exports a Developer ID
build, verifies that the entitlements the app depends on are actually present, notarizes,
staples, builds a styled drag-to-install DMG via `Scripts/package-dmg.sh`, and generates the
Sparkle appcast. It needs a Developer ID certificate and a `notarytool` keychain profile — see
the header of the script. Override the profile name with `NOTARY_PROFILE=...`.

It prints three files to upload to the site root: the DMG, the zip, and `appcast.xml`. The zip
is kept in `build/releases/`, which survives between runs on purpose — the appcast is generated
from every archive in there, so a directory holding only the newest build would produce a feed
that has forgotten every earlier version.

### Updates

Updates go through [Sparkle](https://sparkle-project.org). `SUFeedURL` in `Config/Info.plist`
points at the appcast, `SUPublicEDKey` is the key every build must be signed with, and the app
checks once a day on its own.

The matching **private key lives in the maintainer's login keychain** (service
`https://sparkle-project.org`, account `ed25519`) and is the only thing that can sign an update
existing installs will accept. Back it up offline:

```
./Tools/sparkle/bin/generate_keys -x sparkle-private-key.txt
```

Losing it means no future build can ever be shipped as an update — every install would have to
be replaced by hand. Never commit the export.

`Scripts/fetch-sparkle-tools.sh` puts Sparkle's command-line tools in `Tools/` at the exact
version the app links against, read from `Package.resolved` rather than written down anywhere.
`release.sh` calls it, and refuses to finish if the generated appcast carries no signature —
`generate_appcast` omits the signature *silently*, with a success message, when the archived
app has no `SUPublicEDKey` to verify it with, and the result is a feed every install refuses.

**If you fork and distribute your own builds, change `SUFeedURL` and generate your own keys** —
otherwise your users receive updates from someone else's release channel.

### Translations

```
Scripts/check-localization.sh tr
```

Reports every string the app shows that has no translation, using Xcode's own export rather
than a search through the source: SwiftUI's string literals are never a call to anything, so
nothing short of the compiler finds them all. `release.sh` runs it and stops if anything is
missing.

## Architecture

```
tabmenu/
├── App/                  Composition root, AppDelegate, status item + popover
├── Core/
│   ├── DesignSystem/     Shared cards, metric rows, usage bars
│   ├── Hotkeys/          Carbon hot key registration, recorder field, action catalog
│   ├── Permissions/      Accessibility trust tracking
│   ├── Preferences/      UserDefaults-backed observable settings
│   ├── Support/          Formatting helpers
│   ├── System/           Launch at login, paste simulation, power assertions
│   └── UI/               Floating panel factory
└── Features/
    ├── Clipboard/        Monitor, storage, floating panel, popover list
    ├── Dock/             Dock icon lister, hover monitor, preview panel
    ├── Hardware/         SMC sensors, fans, battery condition, charge limit, helper client
    ├── KeepAwake/        Power assertion session, durations, popover card
    ├── MenuBar/          Popover root and tabs
    ├── MenuBarManager/   Menu bar sections, hidden items strip, item search, tint, spacing
    ├── MenuPalette/      Command palette over the frontmost app's menu bar
    ├── Mixer/            Per-app volume via process taps, DDC display brightness
    ├── Notch/            Notch geometry, design system, file shelf, media control, panel
    ├── OCR/              Screen region selection and Vision text recognition
    ├── Onboarding/       Permission walkthrough on first launch
    ├── PresentationMode/ Coordinated do-not-disturb across the other services
    ├── Settings/         Settings window
    ├── SystemMonitor/    Samplers, collector actor, dashboard
    ├── WindowManager/    Zones, Accessibility bridge, placement service
    ├── WindowPreview/    ScreenCaptureKit thumbnail service
    └── WindowSwitcher/   Window enumeration, switcher panel, app launcher
```

```
Shared/                   Compiled into both the app and the helper
├── HelperProtocol.swift  The privileged XPC contract
└── SMC/                  SMC wire format, and the charge control built on it
Helper/                   MagicPlusHelper, a launchd daemon of about 200 lines
```

Services are `@Observable` and main-actor isolated. Metric sampling runs inside a
`MetricsCollector` actor so a slow sample never blocks the UI or overlaps the next tick.
Clipboard history is stored in `~/Library/Application Support/tabmenu`, with image
payloads written as separate files and pruned when their entries are removed.

The app icon is drawn in code by `Scripts/GenerateAppIcon.swift`, which exports every slot of
`AppIcon.appiconset`. The design stays editable, and re-exporting is deterministic.

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for setup, the
house style, and a few API constraints worth knowing before you start (private symbols,
MediaRemote, the sandbox). Security problems go through
[SECURITY.md](SECURITY.md), privately, not through public issues.

## License

[MIT](LICENSE) © Emre Ramazanoğlu.

Sparkle, the only dependency, is likewise MIT licensed.

## Deliberately out of scope

These are not oversights. Each one is either impossible on current macOS without private or
entitlement-gated APIs, or a deliberate scope decision:

- Replacing the system ⌘Tab switcher (needs an event tap over a system-reserved shortcut)
- Capturing system notifications in the notch (no public API exposes them)
- Rich metadata (artwork, position) for browser and other third-party players — the private
  MediaRemote API that would provide it is entitlement-gated
- Running Shortcuts from the notch panel
- Replacing the volume and brightness HUDs (the system HUD cannot be suppressed)
- Dock folder previews, calendar and media widgets
- Trackpad gestures on previews, shake-to-minimise
- Pinning the Dock to one display
- Disk cleaning
- Fan control. Reading fan speed needs nothing; setting it means writing to the SMC as root,
  and a mistake there cooks the machine rather than merely annoying its owner
- Keyboard cleaning mode
- iCloud sync
- Auto-layout of all open windows
- Dragging menu bar items around for you. macOS already moves them with ⌘-drag, and
  simulating that gesture breaks in a different way with every release
