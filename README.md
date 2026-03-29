# Angy

![Angy mascot](https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRb70TVbvcjEU8LZAsWyVCsrFZO2thUTz-zRw&s)

Angy is a local macOS menu-bar companion for coding sessions. The primary Angy follows the active Codex or Ghostty window, extracts visible text with Accessibility and OCR, scores frustration locally, and reacts with stickers, quips, sounds, and a full rage/explosion sequence when a session goes bad.

The repository currently ships three targets:

- `AngyCore`: shared analysis, state, control, and rendering primitives
- `Angy`: the macOS accessory app in `Sources/AngyApp`
- `AngyCLI`: a local CLI for driving the running app through its control plane

## Current implementation

- Menu-bar macOS accessory app with no normal Dock window
- Primary Angy that auto-follows the frontmost supported session window
- Default tracking for `Codex` and `Ghostty` via bundle ids `com.openai.codex` and `com.mitchellh.ghostty`
- Ghostty launcher detection so Angy can ignore the terminal that launched it and follow Codex instead when appropriate
- Transparent borderless overlay pinned near the tracked window and draggable within screen bounds
- Spawned Angys for additional windows, tagged as `#1`, `#2`, and so on
- Pinned spawned companions auto-remove themselves when their target window disappears
- Hybrid text ingestion:
  - Accessibility text first when available
  - Vision OCR fallback from live window capture when Accessibility is unavailable or too thin
- Local sentiment analysis using Apple `NaturalLanguage` plus coding-specific trigger heuristics
- Activity classification with `default`, `reading`, `thinking`, `blocked`, and `celebrating` modes
- Emotion states with `calm`, `curious`, `annoyed`, and `furious`
- Overlay presentation features:
  - rage meter with critical pulse
  - sticker rotation driven by emotion, activity, and matched triggers
  - contextual quips
  - optional sound cues
  - explosion animation followed by a tombstone state after sustained critical rage
- Local hate-mail generation with cooldowns, written to `~/Desktop/Angy Hate Mail` when enabled
- Menu-bar controls for spawning, attaching, pausing, resuming, retargeting, exploding, overriding state, and writing hate mail
- Local authenticated control plane on `127.0.0.1` with discovery metadata published to `~/Library/Application Support/Angy/control-plane.json`
- CLI support for listing windows and instances, spawning and removing companions, retargeting, pausing and resuming, forcing explosions, writing hate mail, and mutating settings

## Sticker and asset pipeline

Angy resolves sticker assets from:

- bundled resources in `Sources/AngyApp/Resources/Stickers`
- the repo root
- `overlay-assets/`
- `gif/`
- `ANGY_OVERLAY_ASSETS` if set

Supported asset formats include raster frames (`png`, `jpg`, `jpeg`, `gif`, `webp`, `tiff`, `bmp`) and video stickers (`webm`, `mp4`, `mov`, `m4v`).

The current fallback overlay asset in this repo is `overlay-assets/default.webm`. Video sticker decoding prefers `ffmpeg` and `ffprobe` when they are available on `PATH`, then falls back to a WebKit-based decoder.

## Requirements

- macOS 14+
- `Accessibility` permission for UI text extraction
- `Screen Recording` permission for OCR fallback
- Optional but recommended: `ffmpeg` and `ffprobe` on `PATH` for video sticker assets

If only one permission is granted, Angy still runs but analysis degrades to the remaining extraction path. If neither permission is granted, the overlay can launch but live session analysis effectively stops.

## Run

Start the app:

```bash
swift run Angy
```

Useful environment variables:

```bash
ANGY_DEBUG=1 swift run Angy
ANGY_OVERLAY_ASSETS=/absolute/path/to/assets swift run Angy
```

On first run, Angy will prompt for missing macOS permissions and can open the relevant System Settings pages.

## CLI

The CLI talks to the running app's local control plane, so `Angy` must already be running.

Examples:

```bash
swift run AngyCLI windows list
swift run AngyCLI instances list
swift run AngyCLI instances spawn --frontmost
swift run AngyCLI instances spawn --window-id 1234
swift run AngyCLI instances pause primary
swift run AngyCLI instances resume '#1'
swift run AngyCLI instances target '#1' --window-id 5678
swift run AngyCLI instances set-state '#1' furious
swift run AngyCLI instances clear-state '#1'
swift run AngyCLI instances explode '#1'
swift run AngyCLI instances hate-mail '#1'
swift run AngyCLI settings get
swift run AngyCLI settings set hateMailEnabled true
swift run AngyCLI settings set pauseAll true
```

Full CLI usage:

```text
AngyCLI windows list [--json]
AngyCLI instances list [--json]
AngyCLI instances spawn --frontmost
AngyCLI instances spawn --window-id <id>
AngyCLI instances remove <id|#tag>
AngyCLI instances pause <id|#tag>
AngyCLI instances resume <id|#tag>
AngyCLI instances target <id|#tag> --window-id <id>
AngyCLI instances set-state <id|#tag> <calm|curious|annoyed|furious>
AngyCLI instances clear-state <id|#tag>
AngyCLI instances explode <id|#tag>
AngyCLI instances hate-mail <id|#tag>
AngyCLI settings get [--json]
AngyCLI settings set <key> <value>
```

Currently supported mutable settings are:

- `pauseAll`
- `hateMailEnabled`

## Test

```bash
swift test
```

## Repo notes

- [Package.swift](Package.swift) defines the package targets `Angy`, `AngyCore`, `AngyCLI`, `AngyCoreTests`, and `AngyAppTests`.
- [Sources/AngyApp/AngyHiveCoordinator.swift](Sources/AngyApp/AngyHiveCoordinator.swift) owns the menu-bar app, spawned companion lifecycle, and control plane.
- [Sources/AngyApp/AngyController.swift](Sources/AngyApp/AngyController.swift) owns per-instance tracking, analysis, overlay state, sounds, explosion logic, and permission onboarding.
- [Sources/AngyCLI/main.swift](Sources/AngyCLI/main.swift) exposes the control plane from the terminal.
