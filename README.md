# Angy

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

## Team Members

<table>
	<tbody>
        <tr>
            <td align="center">
                <a href="https://github.com/weisintai">
                    <img src="https://avatars.githubusercontent.com/u/59339889?v=4" width="100;" alt=""/>
                    <br />
                    <sub><b>Wei Sin</b></sub>
                </a>
                <br />
            </td>
            <td align="center">
                <a href="https://github.com/injaneity">
                    <img src="https://avatars.githubusercontent.com/u/44902825?v=4" width="100;" alt=""/>
                    <br />
                    <sub><b>Zane Chee</b></sub>
                </a>
                <br />
            </td> 
            <td align="center">
                <a href="https://github.com/gongahkia">
                    <img src="https://avatars.githubusercontent.com/u/117062305?v=4" width="100;" alt="gongahkia"/>
                    <br />
                    <sub><b>Gabriel Ong</b></sub>
                </a>
                <br />
            </td>
        </tr>
	</tbody>
</table>

## Repo notes

- [Package.swift](Package.swift) defines the package targets `Angy`, `AngyCore`, `AngyCLI`, `AngyCoreTests`, and `AngyAppTests`.
- [Sources/AngyApp/AngyHiveCoordinator.swift](Sources/AngyApp/AngyHiveCoordinator.swift) owns the menu-bar app, spawned companion lifecycle, and control plane.
- [Sources/AngyApp/AngyController.swift](Sources/AngyApp/AngyController.swift) owns per-instance tracking, analysis, overlay state, sounds, explosion logic, and permission onboarding.
- [Sources/AngyCLI/main.swift](Sources/AngyCLI/main.swift) exposes the control plane from the terminal.
