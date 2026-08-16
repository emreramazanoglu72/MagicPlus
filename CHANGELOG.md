# Changelog

All notable changes to MagicPlus are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0] — 2026-08-15

First public release.

### Added

- **Window manager**: 11 placement commands with width cycling, drag-to-edge snapping with a
  target preview, per-app placement rules, saved workspace layouts, multi-display support and
  a configurable gap.
- **Notch panel**: a Dynamic Island style surface that idles at exactly the hardware notch
  size — file shelf, playback control, Calendar agenda with Join links, camera mirror,
  volume and screenshot activities, threshold alerts, and a strip fallback for displays
  without a notch.
- **Clipboard history**: text, files and images with a Spotlight-style keyboard-driven panel,
  paste-time transforms, pinning, and detection of sensitive content that is never recorded.
- **Window switcher**: alt-tab across every window of every app, doubling as a launcher.
- **Dock previews**: live window previews on Dock icon hover, with close and minimise.
- **System monitor**: CPU, memory, disk, network and top processes, with an optional menu bar
  readout and visibility-driven sampling.
- **Keep awake**: IOKit power assertions with an optional timer and a menu bar indicator.
- **Meeting and safety tools**: microphone and camera indicators, system-wide panic mute,
  presentation mode, on-device OCR capture, window rescue after display changes, a menu
  command palette, and quick notes.
- **Audio mixer**: per-app volume and mute over macOS process taps, plus external display
  brightness over DDC/CI.
- **Localization**: English and Turkish from a single String Catalog, with an in-app language
  picker.
- **Updates**: Sparkle, with a signed and notarized DMG produced by `Scripts/release.sh`.

[Unreleased]: https://github.com/emreramazanoglu72/MagicPlus/compare/v1.0...HEAD
[1.0]: https://github.com/emreramazanoglu72/MagicPlus/releases/tag/v1.0
