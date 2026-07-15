# QA: testing voice without a device

The mic and Apple speech-to-text are the only parts of voice that need real hardware, and they are
not where bugs live. **Everything after the transcript string** — command parsing, task selection,
bulk ops, the confirm flow, mutations, navigation — runs headless. Three layers, in order of how
often you use them.

## 1. Scenario suite (run every build)

`FocusFlowTests/VoxdumpVoiceScenarioTests.swift` is the everyday net. Each case reads like a spoken
interaction and runs the REAL pipeline (NavCommandMatcher → NavCommandResolver → in-memory SwiftData
mutation, with BulkDeleteConfirmMatcher for deletes):

```swift
Scenario("complete the second task",
         seed: [.pending("Water plants"), .pending("Buy groceries"), .pending("Call mom")],
         say: "complete the second task",
         expect: .completes(["Buy groceries"]))
```

Add a case = append one line. Run:

```bash
xcodebuild test -project Voxdump.xcodeproj -scheme Voxdump \
  -destination 'platform=iOS Simulator,id=<SIM_UDID>' -derivedDataPath workspace/dd \
  -only-testing:FocusFlowTests/VoxdumpVoiceScenarioTests
```

Related: `VoxdumpNavCommandTests` (matcher + resolver), `VoxdumpTasksCommandIntegrationTests`
(full path vs. real SwiftData), `VoxdumpDestructiveGuardTests` (confirm safety). All run in < 1s.

## 2. Drive the simulator like a voice device (DEBUG)

The app registers `braindump://inject?text=…` in DEBUG. It routes the text through the exact
`transcript → evaluate → command → UI/data` path the mic would, so you can drive the real UI on the
simulator with no mic:

```bash
UDID=<SIM_UDID>
xcrun simctl launch --terminate-running-process $UDID com.maitrayeechoubey.braindumpapp
xcrun simctl openurl $UDID "braindump://tasks"                       # go to the tasks list
xcrun simctl openurl $UDID "braindump://inject?text=complete%20all"  # speak, without speaking
xcrun simctl openurl $UDID "braindump://inject?text=clear%20all"
xcrun simctl openurl $UDID "braindump://inject?text=yes"             # answer the confirm
```

The tasks list must be visible (it observes the inject notification). iOS may show an "Open in
Voxdump?" prompt the first time — tap Open once. Only DEBUG builds handle `inject`.

## 3. Harvest real transcripts from device logs (compounding coverage)

You test on device occasionally; make each session permanent. After capturing a logarchive:

```bash
log collect --device --last 30m --output workspace/vox-device.logarchive
python3 scripts/harvest_transcripts.py
```

It writes `workspace/harvested_transcripts.txt` (every real "heard '…' -> action" pair, deduped) and
`workspace/harvested_scenarios.swift` (paste-ready stubs). Move any new/interesting utterance into
`VoxdumpVoiceScenarioTests` with an expected outcome. Real ASR noise ("Receipt except" for "accept",
"Mark go" partials) becomes a permanent regression test instead of something you re-test by hand.

## 4. Run the REAL voice path on the simulator (mic + recognizer + arm/re-arm lifecycle)

The simulator DOES capture the Mac's microphone and `SFSpeechRecognizer` runs there. The app defaults
to text mode on the sim, but launch with `VOX_FORCE_VOICE=1` to turn on the real always-on voice path
(mic → recognizer → the arm/re-arm coordinator). This is how the LISTENER LIFECYCLE (the part that
repeatedly regressed) gets verified off-device.

```bash
UDID=<SIM_UDID>; BUNDLE=com.maitrayeechoubey.braindumpapp
xcrun simctl privacy $UDID grant microphone $BUNDLE      # speech-recognition is granted at first run
SIMCTL_CHILD_VOX_FORCE_VOICE=1 xcrun simctl launch --terminate-running-process $UDID $BUNDLE
# ...navigate Home <-> Tasks..., then read the sim's own log:
xcrun simctl spawn $UDID log show --last 60s --predicate 'subsystem == "com.braindump"' --info --debug --style compact | grep listen
```

A HEALTHY log shows one clean arm per surface change:
```
listen[home]: armed       # on Home
listen[tasks]: armed      # after navigating to Tasks
```
A BROKEN (thrashing) log interleaves `home`/`tasks` every 1-3s — that's the two-loop race (§24).

Feeding synthesized speech automatically needs a virtual input device (e.g. BlackHole) set as the
Mac's default input, then `say`/`afplay` into it — the sim reads the Mac's default input. Without one,
speak into the Mac mic manually, OR use the `braindump://inject` seam (layer 2) which covers routing.

## What still needs a physical device

Apple's on-device ASR QUALITY on real speech/accents/noise (the sim uses the Mac mic) and Siri launch.
Everything else — command decisions, task selection, the confirm flow, AND the always-on arm/re-arm
lifecycle — is now verifiable off-device via layers 1–4.
