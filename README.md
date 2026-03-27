# Angy

![Angy mascot](https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRb70TVbvcjEU8LZAsWyVCsrFZO2thUTz-zRw&s)

Angy is a local macOS companion that watches the frontmost Codex window and hangs a tiny ASCII panda just outside the frame. It uses Accessibility text first, falls back to OCR, runs lightweight sentiment analysis with Apple `NaturalLanguage`, and reacts with escalating poses and quips when the session looks rough.

## Mascot

The official Angy mascot is the tiny back-turned panda. The in-app companion is still rendered as ASCII for the MVP, but the README, pitch, and visual identity should treat this panda as the character we are building around.

## What ships in this MVP

- Background macOS app with no normal Dock window
- Transparent click-through overlay pinned to the active Codex window
- Hybrid text extraction: Accessibility first, OCR fallback
- Local sentiment scoring plus coding-specific frustration heuristics
- Four companion states: `calm`, `curious`, `annoyed`, `furious`
- Startup onboarding for Accessibility and Screen Recording permissions

## Run

```bash
swift run Angy
```

On first run, macOS will likely require:

- `Accessibility`
- `Screen Recording`

Without those, Angy can still launch, but live analysis degrades or disables depending on which permission is missing.

## Test

```bash
swift test
```

## Notes

- `Codex` is targeted via bundle id `com.openai.codex`.
- The overlay hides whenever Codex is not the frontmost app.
- This package is structured as `AngyCore` for testable analysis/state logic and `AngyApp` for the macOS UI and OS integrations.
