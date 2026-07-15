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

## What still needs a device

Only the mic hardware + Apple's on-device ASR (audio → transcript) and Siri launch. The command
DECISION logic — where every reported bug has been — is fully covered off-device by layers 1–3.
