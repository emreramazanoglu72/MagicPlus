# MagicPlus

[![CI](https://github.com/emreramazanoglu72/MagicPlus/actions/workflows/ci.yml/badge.svg)](https://github.com/emreramazanoglu72/MagicPlus/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey)

A macOS menu bar utility that combines window tiling, clipboard history, a Dynamic Island
style notch panel, per-app volume and system monitoring in one place. No account, no
telemetry, no network calls beyond the update check.

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

Activities have priorities, so a meeting about to start is never buried under a track change,
and repeated volume presses replace one another instead of queueing.

- **Volume**: pressing the hardware volume keys shows the level in the notch, read through
  CoreAudio so it keeps up with the keystroke
- **Screenshots** land on the shelf by themselves — take one and drag it straight where it
  belongs, without it ever cluttering the Desktop
- **Downloads** announce themselves in the island as they arrive, AirDrop included
- **File shelf**: drop files onto the panel to park them, drag them back out into any app,
  share or AirDrop the whole set, reveal in Finder. The shelf survives restarts and drops
  entries whose files have moved
- **Playback**: transport controls work on whatever currently owns the media session,
  including a YouTube tab in any browser. Spotify and Apple Music additionally report track,
  artist, album and artwork; browser tabs are named from their title
- **Agenda**: the next meetings from Calendar, each with a Join button when a Zoom, Meet,
  Teams, Webex or Jitsi link can be found in the invite
- **Mirror**: live camera preview, for checking yourself before a call
- Displays without a notch get a strip in the middle of the menu bar with the same behaviour
- The panel only intercepts the pointer while open, so the menu bar stays clickable
- The waveform animates only while audio actually plays, and freezes under Reduce Motion

Playback control uses the hardware media keys rather than the private MediaRemote
framework, which returns nothing without a special entitlement on current macOS.

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
  `ProcessInfo.thermalState`, not a sensor read: per-sensor temperature and fan RPM on Apple
  Silicon need private IOKit interfaces, and thermal pressure is the signal the system itself
  throttles on
- Optional CPU or memory readout in the menu bar
- Sampling cadence follows visibility: suspended when nothing is shown, 3s in the
  background, 1.5s while the popover is open

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
- **Screen Recording permission**, optional. Only used to capture window thumbnails for the
  Dock previews and the switcher grid; without it both fall back to application icons.
- **Automation permission** for Music, Spotify and browsers, optional. Only used to read
  what is playing. Transport controls work without it.
- **Camera permission**, optional. Only used by the notch panel's Mirror tab.

The app runs unsandboxed because the Accessibility API, IOKit statistics, and process
listing are unavailable inside the App Sandbox. It is therefore distributable outside the
Mac App Store only.

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
durations, shortcut encoding and default-collision checks, and workspace layout matching.

## Releasing

```
Scripts/release.sh 1.1
```

Runs the tests, archives, exports a Developer ID build, verifies that the entitlements the
app depends on are actually present, notarizes, staples, and builds a styled drag-to-install
DMG via `Scripts/package-dmg.sh`. It needs a Developer ID certificate and a `notarytool`
keychain profile — see the header of the script. Override the profile name with
`NOTARY_PROFILE=...`.

Updates go through [Sparkle](https://sparkle-project.org): `SUFeedURL` in `Config/Info.plist`
points at the maintainer's appcast, and each build is signed with an EdDSA key.
**If you fork and distribute your own builds, change `SUFeedURL`** — otherwise your users
receive updates from someone else's release channel.

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
    ├── KeepAwake/        Power assertion session, durations, popover card
    ├── MenuBar/          Popover root and tabs
    ├── MenuPalette/      Command palette over the frontmost app's menu bar
    ├── Mixer/            Per-app volume via process taps, DDC display brightness
    ├── Notch/            Notch geometry, file shelf, media control, panel
    ├── OCR/              Screen region selection and Vision text recognition
    ├── Onboarding/       Permission walkthrough on first launch
    ├── PresentationMode/ Coordinated do-not-disturb across the other services
    ├── Settings/         Settings window
    ├── SystemMonitor/    Samplers, collector actor, dashboard
    ├── WindowManager/    Zones, Accessibility bridge, placement service
    ├── WindowPreview/    ScreenCaptureKit thumbnail service
    └── WindowSwitcher/   Window enumeration, switcher panel, app launcher
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
- Display brightness control and keyboard cleaning mode
- iCloud sync
- Auto-layout of all open windows
