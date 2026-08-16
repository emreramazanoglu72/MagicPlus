# Contributing to MagicPlus

Thanks for taking the time. This is a small project, so the process is short.

## Getting set up

```bash
git clone https://github.com/emreramazanoglu72/MagicPlus.git
cd MagicPlus
open tabmenu.xcodeproj
```

Xcode resolves [Sparkle](https://github.com/sparkle-project/Sparkle) on first open. Building
and running the tests needs no Apple Developer account — the app is signed ad-hoc.

To sign with your own team (needed only if you want to distribute a build), copy the
signing template:

```bash
cp Config/Local.example.xcconfig Config/Local.xcconfig
# then put your Team ID in it
```

`Config/Local.xcconfig` is gitignored, so your Team ID never lands in a commit and no one
else's setting ever conflicts with yours.

## Running the app while developing

The app is unsandboxed and leans on permissions that macOS grants **per binary path**:

- **Accessibility** is required for anything window related. macOS remembers the grant per
  build location, so after the first launch from Xcode you usually only grant it once.
- After a rebuild, macOS sometimes keeps the stale grant. If window commands silently stop
  working, remove the app from System Settings → Privacy & Security → Accessibility and add
  it again.
- **Screen Recording** is optional (window thumbnails), **Camera** is optional (Mirror tab),
  **Calendar** is optional (agenda).

Debug builds write their data to the same place as release builds
(`~/Library/Application Support/MagicPlus`), so be aware that testing destructive changes to
clipboard history affects your real history.

## Tests

```bash
xcodebuild test -project tabmenu.xcodeproj -scheme tabmenu -destination 'platform=macOS'
```

CI runs exactly this on every pull request. The suite deliberately covers the logic that
fails *silently* rather than loudly — zone geometry, coordinate-space conversion, clipboard
fingerprinting, meeting-link extraction, notch activity priorities, shortcut encoding,
workspace layout matching.

If you add logic that could silently produce a wrong result, add a test for it. Pure
functions are extracted specifically so they can be tested without a running app; keep that
pattern rather than testing through the UI.

## Style

- Swift code, comments, commit messages, type and file names: **English**.
- Match the surrounding code. The project uses `@Observable`, main-actor isolation for
  services, and small focused files under `Features/<Feature>/`.
- Comments explain **why**, not what. If a comment restates the code, drop it.
- No new third-party dependencies without discussing it in an issue first. The only
  dependency today is Sparkle, and that is for updates alone.

## Pull requests

1. Open an issue first for anything larger than a bug fix, so nobody builds the wrong thing.
2. One logical change per pull request. Keep diffs minimal — avoid drive-by reformatting.
3. Make sure `xcodebuild test` passes locally.
4. Describe what you changed and how you verified it. "Tested manually" is fine when the
   change is UI, as long as you say what you actually did.

## Things worth knowing before you dig in

- **Private APIs**: `ExternalDisplayBrightness.swift` resolves `IOAVService*` symbols at
  runtime for DDC brightness. That is fine for direct distribution but would be an automatic
  App Store rejection. Do not spread this pattern to other files.
- **MediaRemote** is entitlement-gated on current macOS and returns nothing, which is why
  playback control posts hardware media key events instead. Please don't "fix" this by
  reintroducing MediaRemote.
- **Sparkle feed**: `Config/Info.plist` points `SUFeedURL` at the maintainer's appcast. If
  you fork and distribute your own builds, change it — otherwise your users get updates from
  someone else's release channel.
- **App Sandbox** is off on purpose: the Accessibility API, IOKit statistics and process
  enumeration are all unavailable inside it. This app cannot ship on the Mac App Store.

## Reporting bugs

Use the issue templates. The single most useful thing you can include is the exact steps and
what you expected instead — plus your macOS version and whether you are on Apple Silicon.
