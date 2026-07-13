# Voxdump

Voice dump your chaos. Apple Intelligence organizes it into tasks, on-device, in seconds.
Free forever, no ads, completely private.

Voxdump is voice-first, on-device task capture for people with ADHD. Speak a "brain dump" and
it transcribes on-device, then uses Apple Intelligence (the FoundationModels framework) to turn
it into structured tasks with a category, urgency, timing, and 2 to 4 actionable micro-steps.
Voice commands handle completing, reopening, deleting, listing, reading, and reminding. No
account, no backend, nothing leaves your phone. When Apple Intelligence is unavailable, a
built-in rule-based parser keeps the app working.

The app ships as **Voxdump.app**; the Swift module and source folder are named **FocusFlow**.

## Requirements

- Xcode 26+, iOS 17+ deployment target.
- The AI parsing path needs Apple Intelligence (iPhone 15 Pro or newer on iOS 26+); other
  devices fall back to the rule-based parser.
- [XcodeGen](https://github.com/yonsm/XcodeGen): `brew install xcodegen`.

## Build

```bash
./setup.sh            # generates the Xcode project and opens it
# or, manually:
xcodegen generate
open Voxdump.xcodeproj
```

Then in Xcode: select your signing Team on the **FocusFlow** target and press Cmd+R. The
simulator auto-enables a typed input mode; on a physical iPhone you get voice + Apple Intelligence.

## Layout

- `FocusFlow/` — SwiftUI app source. `AIParsingManager.swift` is the intent-classification and
  task-extraction engine (the FoundationModels prompt lives here).
- `FocusFlowTests/` — deterministic parser and matcher tests (`xcodebuild test`).
- `project.yml` — the XcodeGen spec and single source of truth for build settings and version.
  The `.xcodeproj` is generated from it and is not committed.
