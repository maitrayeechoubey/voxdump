# Handoff: voice listening lifecycle (2026-07-15)

Context doc for a fresh session to continue the voice work. Pair with `docs/MAINTENANCE.md`
(§20-26 are the change-by-change history) and `docs/qa-voice-testing.md` (how to test without a
device). Repo: github.com/maitrayeechoubey/voxdump, branch `main`.

## TL;DR

The always-on voice listening has had repeated lifecycle regressions. The command DECISION logic
(what a transcript maps to) is solid and well-tested. The open items are all about WHEN the mic is
armed as the user navigates between surfaces (Home, Tasks list, Brain Dump sheet). Read "Architecture"
then "Open bugs".

## Architecture (voice)

- **One mic, one owner.** `SpeechManager.shared` (FocusFlow/SpeechManager.swift) is the single
  AVAudioEngine/AVAudioSession/SFSpeechRecognizer owner. A **single-owner coordinator** (§24) manages
  the always-on loop: `listen(as: owner, onFinal:)` / `stopListening(as: owner)`. A generation counter
  makes a new owner supersede the old so stale timers/callbacks bail; `armNext` is cancellable and
  settles 0.35s; after each finalized utterance it auto-continues for the same owner. This fixed the
  Home↔Tasks arm thrash (verified on the sim — see below).
- **Surfaces that listen:**
  - **Home** (`ContentView.HomeView`) — `syncVoice()` calls `speech.listen(as: "home")`; gated by
    `canListen` (passed from ContentView: `navPath.isEmpty && !showBrainDump && !showReentry && !showDrawer`)
    and `!speaker.isSpeaking`. On a finalized utterance: nav command → navigate; else (>=2 words) →
    `onCaptureText` opens the capture sheet seeded with the transcript.
  - **Tasks list** (`AllTasksView`) — `syncVoice()` calls `speech.listen(as: "tasks")`; gated by
    `listeningActive = voiceSupported && handsFree && !showBrainDump && openTaskID == nil`.
  - **Brain Dump sheet** (`BrainDumpSheet` → `CardReviewView`, `EditTaskSheet`) — **STILL USES ITS OWN
    arm loop** (`armVoice`/`scheduleArm`/`speech.startRecording()` directly), NOT the coordinator. This
    is the prime suspect for bugs 2 & 4 (see below). It was left unconverted in §24 because the sheet
    is a single exclusive surface, but the sheet↔Tasks HAND-OFF is not coordinator-mediated.
- **Command engine** (`NavCommand.swift`): `NavCommandMatcher.match(text) -> NavCommand?` (pure) and
  `NavCommandResolver.resolve(cmd, in: [TaskSnapshot]) -> [Int]` (pure). Fully unit-tested.
- **`VoiceEnv.supported`** (SpeechManager.swift): device → true; simulator → true only with
  `VOX_FORCE_VOICE=1`. THIS is how to run the real voice path on the sim.

## Open bugs (as reported 2026-07-15)

### Bug 2 — listening not always active on the Tasks list; stops after a command
"Works on first load, or after going Home then 'show pending'. When I say 'complete first' there, it
completes it and then listening is disabled."
- **Where:** `AllTasksView.syncVoice` / `evaluate` / the coordinator auto-continue in
  `SpeechManager.listen`.
- **Hypotheses (unverified — needs fresh device/sim logs):**
  1. After a command that stays on the page (single `complete`), the coordinator's auto-continue
     (`if gen == listenGeneration { armNext }`) should re-arm, but completing a task mutates SwiftData
     → `AllTasksView` re-renders; check whether that re-render (or the filter section change when the
     completed task leaves the pending list) perturbs `syncVoice`/`listeningActive` or bumps the
     generation via an unexpected `onChange`.
  2. Possible interaction with the sheet's non-coordinator recording if any residual owner state.
- **How to verify:** `VOX_FORCE_VOICE=1` on the sim (or device), then watch
  `xcrun simctl spawn <udid> log show ... | grep -E "listen\[|armed"`. A healthy run re-arms
  `listen[tasks]: armed` after each command. If it stops, add a log in `armNext`'s `guard gen ==` else
  branch to see WHY it bailed.

### Bug 4 — after Accept in the sheet lands on Tasks, listening is dead until you cross-out and re-navigate
"home page and create task page are the best. When I accept the task and land on tasks page, listening
is not working; I have to click the cross, navigate to tasks again from the menu, then listening works."
- **Prime suspect (high confidence):** the Brain Dump sheet's `CardReviewView` uses its OWN arm loop,
  not the coordinator. On Accept: `onComplete` sets `showBrainDump = false` AND `navPath = [.allTasks]`.
  `AllTasksView.onAppear → syncVoice → listen(as:"tasks")` arms (0.35s settle). Meanwhile the sheet's
  `CardReviewView.onDisappear → stopVoice → speech.stopRecording()` runs during dismissal and can fire
  AFTER the tasks arm, killing it. Re-navigating later has no dismissing sheet, so no race → works.
- **Recommended fix:** convert `CardReviewView` and `EditTaskSheet` to the coordinator
  (`speech.listen(as: "review"/"edit") { … }` and `speech.stopListening(as:)`), so the sheet→Tasks
  hand-off is a clean generation supersede instead of a raw stopRecording race. This completes §24.
  Keep the sheet's context-aware command handling (review vs edit) inside the `onFinal` closure.

### Bug 3 — on Home, "show <task>" / "open <task>" navigates to All Tasks instead of opening that task
- **Where:** `ContentView.HomeView.evaluate`, the `.open` case currently does `onShowTasks(.all)`
  (comment: "can't reliably resolve one task from Home"). But HomeView HAS `@Query allTasks`, so it CAN
  resolve.
- **Recommended fix (ready to apply):**
  ```swift
  case .open(let sel):
      let snap = allTasks.map { TaskSnapshot(title: $0.title, isCompleted: $0.isCompleted, createdAt: $0.createdAt) }
      if let i = NavCommandResolver.resolve(.open(sel), in: snap, now: Date()).first {
          onOpenTask(allTasks[i].persistentModelID)   // ContentView pushes [.allTasks, .taskFocus(id)]
      } else {
          onShowTasks(.all)
      }
  ```
  `NavCommandMatcher.match("show call immigration")` already returns `.open(.name("call immigration"))`
  (verified by `test_open_showNamedTask`); only the Home routing needs this change. Verify via
  `braindump://inject?text=show%20call%20mom` on Home → should push the task detail, not the list.

### Bug 1 — FIXED this session
"On the pending page, 'show all tasks' opened the submit-immigration task." Root cause: `show` is an
open-verb and `all` became a selector, so `"show all tasks"` matched `open(.all)` → opened pending #1.
Fixed in `NavCommandMatcher`: `show/view/see/list + all/everything` (without a mutate verb) →
`showTasks(.all)`. Guarded by `VoxdumpNavCommandTests` (test_showAll_*, test_regression_*, test_open_*).

## How to reproduce / verify voice on the simulator (no device)

```bash
UDID=<sim udid>   # iPhone 17 Pro: 7097263B-359E-4A74-BF04-F9BE664AB6D8
BUNDLE=com.maitrayeechoubey.braindumpapp
xcodebuild build -project Voxdump.xcodeproj -scheme Voxdump \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath workspace/dd
xcrun simctl install $UDID workspace/dd/Build/Products/Debug-iphonesimulator/Voxdump.app
xcrun simctl privacy $UDID grant microphone $BUNDLE
SIMCTL_CHILD_VOX_FORCE_VOICE=1 xcrun simctl launch --terminate-running-process $UDID $BUNDLE
# navigate, then:
xcrun simctl spawn $UDID log show --last 60s --predicate 'subsystem == "com.braindump"' --info --debug --style compact | grep -E "listen\[|armed|heard"
```
- `braindump://inject?text=...` (DEBUG) drives the real command path with a transcript (no mic needed),
  observed by Home (when foreground) and the Tasks list.
- For a device logarchive: `log collect --device --last 30m --output workspace/vox-device.logarchive`
  then `python3 scripts/harvest_transcripts.py` to turn real utterances into scenario fixtures.

## Test suites (all fast, run every build)

- `VoxdumpNavCommandTests` — matcher + resolver (81 tests incl. the new open/show-all guards).
- `VoxdumpTasksCommandIntegrationTests` — full command path vs. in-memory SwiftData.
- `VoxdumpVoiceScenarioTests` — data-driven "given tasks, say phrase, expect outcome".
- `VoxdumpListeningBarTests` — bar control visibility (mute vs record mic).
- `VoxdumpDestructiveGuardTests` — bulk-delete confirm safety.
Run: `xcodebuild test ... -only-testing:FocusFlowTests/<suite>`. ~0.5s total.

## Suggested order for the next session

1. Get a fresh device (or `VOX_FORCE_VOICE=1` sim) logarchive reproducing bugs 2 & 4; grep `listen[`.
2. Fix bug 4 by converting the Brain Dump sheet to the coordinator (highest-confidence hypothesis).
3. Re-check bug 2 after bug 4 (they may share the sheet-handoff root cause); if not, instrument
   `armNext`'s bail path.
4. Apply the bug-3 Home `.open` fix (code above) + add a scenario/injection test.
5. Keep every change covered by a pure test or a `braindump://inject` sim check before shipping.
