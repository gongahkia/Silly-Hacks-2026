# `Angy` - So Codex can finally judge you

<div align="center">
	<img src="https://github.com/user-attachments/assets/3faaf764-dc57-4baa-807f-c65ce049da9e">
	<br>
	<i>I have no mouth but I must meme.</i>
</div>

## Demo

![](./asset/demo.gif)

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

## Usage

### Requirements

- macOS 14+
- Codex CLI logged in (`codex login`)
- `Accessibility` permission for UI text extraction (legacy mode only)
- `Screen Recording` permission for OCR fallback (legacy mode only)
- Optional but recommended: `ffmpeg` and `ffprobe` on `PATH` for video sticker assets

By default, Angy reads Codex assistant output from `~/.codex/sessions/**/rollout-*.jsonl`.
If you use legacy mode, only one permission is required for degraded extraction, and both permissions together unlock the full Accessibility+OCR path.

### Run `Angy`

```bash
swift run Angy
```

### Optional `.env` config

```bash
ANGY_DEBUG=1 swift run Angy
ANGY_OVERLAY_ASSETS=/absolute/path/to/assets swift run Angy
ANGY_CODEX_HOME=/absolute/path/to/.codex swift run Angy
ANGY_LEGACY=1 swift run Angy
```

### Optional Codex App Server setup

If you want Codex running through an explicit app-server endpoint:

```bash
# Terminal 1
codex app-server --listen ws://127.0.0.1:8765

# Terminal 2
codex --remote ws://127.0.0.1:8765

# Terminal 3
swift run Angy
```

As long as Codex writes session rollouts into the same `~/.codex` directory Angy is watching, Angy picks up the assistant output.

### CLI

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
swift run AngyCLI instances hate-mail '#1' --force
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
AngyCLI instances hate-mail <id|#tag> [--force]
AngyCLI settings get [--json]
AngyCLI settings set <key> <value>
```

Currently supported mutable settings are:

- `pauseAll`
- `hateMailEnabled`

## Nerd details 

- [Package.swift](Package.swift) defines the package targets `Angy`, `AngyCore`, `AngyCLI`, `AngyCoreTests`, and `AngyAppTests`.
- [Sources/AngyApp/AngyHiveCoordinator.swift](Sources/AngyApp/AngyHiveCoordinator.swift) owns the menu-bar app, spawned companion lifecycle, and control plane.
- [Sources/AngyApp/AngyController.swift](Sources/AngyApp/AngyController.swift) owns per-instance tracking, analysis, overlay state, sounds, explosion logic, and permission onboarding.
- [Sources/AngyCLI/main.swift](Sources/AngyCLI/main.swift) exposes the control plane from the terminal.
