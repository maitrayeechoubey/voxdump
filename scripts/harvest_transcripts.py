#!/usr/bin/env python3
"""
Harvest real voice transcripts from a Voxdump device logarchive into QA fixtures.

Every device session logs lines like:
    [com.braindump:command] tasks heard 'Complete all' -> complete(...)
    [com.braindump:command] review heard 'Edit' editing=false -> edit
This turns each real (often garbled) utterance into a permanent test case, so an occasional
device session compounds into the automated suite instead of being re-tested by hand.

Usage:
    python3 scripts/harvest_transcripts.py [path/to/vox-device.logarchive]

Default archive: workspace/vox-device.logarchive. Writes two things to workspace/:
    harvested_transcripts.txt   — deduped "surface | transcript | observed" report to eyeball
    harvested_scenarios.swift   — paste-ready Scenario/XCTest stubs for VoxdumpVoiceScenarioTests

Nothing here runs the app; it only reads logs via `log show`.
"""
import subprocess
import sys
import re
import os
from collections import OrderedDict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ARCHIVE = os.path.join(REPO, "workspace", "vox-device.logarchive")
OUT_DIR = os.path.join(REPO, "workspace")

# "tasks heard 'X' -> Y"  |  "review heard 'X' editing=false -> Y"
HEARD = re.compile(r"(tasks|review) heard '(.+?)'(?: editing=\w+)? -> (.+?)\s*$")


def load_lines(archive: str) -> list[str]:
    if not os.path.exists(archive):
        sys.exit(f"logarchive not found: {archive}\nCollect one with:\n"
                 f"  log collect --device --last 30m --output {archive}")
    cmd = ["/usr/bin/log", "show", "--archive", archive,
           "--predicate", 'subsystem == "com.braindump" AND category == "command"',
           "--info", "--debug", "--style", "compact"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    return out.stdout.splitlines()


def harvest(lines: list[str]):
    # key: (surface, transcript) -> observed action (last one wins; dedupes repeats)
    seen = OrderedDict()
    for ln in lines:
        m = HEARD.search(ln)
        if not m:
            continue
        surface, transcript, observed = m.group(1), m.group(2).strip(), m.group(3).strip()
        if transcript:
            seen[(surface, transcript)] = observed
    return seen


def swift_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main():
    archive = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_ARCHIVE
    seen = harvest(load_lines(archive))
    os.makedirs(OUT_DIR, exist_ok=True)

    report = os.path.join(OUT_DIR, "harvested_transcripts.txt")
    with open(report, "w") as f:
        f.write(f"# Harvested from {archive}\n# {len(seen)} unique (surface, transcript) pairs\n\n")
        for (surface, transcript), observed in seen.items():
            f.write(f"{surface:6} | {transcript!r:50} | {observed}\n")

    stubs = os.path.join(OUT_DIR, "harvested_scenarios.swift")
    with open(stubs, "w") as f:
        f.write("// Paste real transcripts into VoxdumpVoiceScenarioTests.scenarios(), then set the\n")
        f.write("// expected outcome. Regression guard: these are utterances the device actually heard.\n\n")
        for (surface, transcript), observed in seen.items():
            f.write(f'// {surface} observed: {observed}\n')
            f.write(f'Scenario("{swift_escape(transcript)}", seed: three, expect: .completes([])),  // TODO set expectation\n')

    tasks = sum(1 for (s, _) in seen if s == "tasks")
    review = sum(1 for (s, _) in seen if s == "review")
    print(f"Harvested {len(seen)} unique transcripts ({tasks} tasks, {review} review).")
    print(f"  report: {report}")
    print(f"  stubs:  {stubs}")
    print("Eyeball the report, then move any new ones into VoxdumpVoiceScenarioTests with an expectation.")


if __name__ == "__main__":
    main()
