# Voxdump — Product Specification v0.1

**Status:** Draft for PM review  
**Date:** July 2026  
**Constraint:** All features must run 100% on-device, $0 backend, no monetization (personal hobby project)

---

## Context

Voxdump v1.0 is live on the App Store. It solves one problem well: a user opens the app, speaks a stream of consciousness, and Apple Intelligence extracts structured tasks from it. The core loop works.

This spec covers the next layer of value: making Voxdump a system-wide task capture layer, not just a standalone app.

---

## Goals

- Reduce the surface area where tasks get lost (cross-app capture)
- Make captured tasks actionable inside the Apple ecosystem (Calendar, Reminders)
- Expand to longer-form capture use cases (meetings)
- Fix the one broken feature in v1.0 (reminders)

## Non-Goals

- Backend sync, user accounts, or cloud storage outside of iCloud
- Android
- Third-party API integrations (no OpenAI, no Zapier, no Notion)
- Monetization of any kind

---

## Feature 1: Fix Reminders (end-to-end)

**Priority:** P0 — ship before anything else  
**Effort:** Small (1–2 days)

### Problem

When a user says "remind me at 3pm to call the doctor," the AI correctly classifies this as `schedule_reminder` and extracts the time. But the actual notification scheduling via `UNUserNotificationCenter` was never verified end-to-end. In testing, the reminder silently failed with no feedback to the user.

### Expected UX

1. User speaks: "remind me in 30 minutes to take my medication"
2. App parses time expression → resolves to an absolute `Date`
3. App schedules a `UNNotificationRequest` with that date
4. App speaks confirmation: "Reminder set for 2:34 PM"
5. At the scheduled time, a push notification fires with the task hint as the body

### Edge Cases

| Input | Expected behavior |
|-------|-------------------|
| "remind me at 3pm" | Schedules for 3:00 PM today; if 3pm has passed, schedules for tomorrow |
| "remind me in 30 minutes" | Resolves relative to current time |
| "remind me tomorrow morning" | Schedules for 9:00 AM tomorrow (configurable default) |
| "remind me to call John" (no time) | Routes to task_creation, not a reminder — already fixed in v1.0 |
| Notification permission denied | Speaks error: "I can't set reminders without notification permission. Go to Settings to enable it." |

### Technical Notes

- Use `DateComponentsFormatter` + simple NLP for relative time parsing ("in 30 minutes", "tomorrow morning")
- `UNUserNotificationCenter.add(request)` with the resolved date
- Store pending reminders in SwiftData so the user can see/cancel them
- "Tomorrow morning" = 9:00 AM default, surfaced as a setting later

---

## Feature 2: Share Extension — System-Wide Task Capture

**Priority:** P1 — highest new-feature impact  
**Effort:** Medium (3–5 days)

### Problem

Tasks don't only come from voice. They come from an email someone forwarded, a WhatsApp message, a note written at midnight, a Slack thread. Today, the user has to manually remember to open Voxdump and re-dictate something they already read. That's friction — and friction is what Voxdump is supposed to eliminate.

### Solution

A Share Extension that makes Voxdump available in the iOS Share Sheet from any app. The user selects text in any app, taps Share → Voxdump, and Apple Intelligence extracts tasks from that text exactly as it would from a voice transcript.

### UX Flow

```
[Any app: Mail, WhatsApp, Notes, Messages, Safari]
    ↓ User selects text
    ↓ Taps Share
    ↓ Taps "Voxdump"
[Share Extension UI appears as a sheet]
    → Shows selected text in a preview
    → "Extract Tasks" button
    ↓ Apple Intelligence parses the text
[Task review cards — same UI as voice flow]
    → User swipes to accept/dismiss each task
    ↓ Accepted tasks saved to SwiftData
[Confirmation]
    → "3 tasks added" banner
    → Extension dismisses, user returns to original app
```

### What this unlocks

| Source | Example |
|--------|---------|
| Mail | Forward a project brief → extract all action items |
| WhatsApp | Share a message thread → extract follow-ups |
| Apple Notes | Share a meeting note → extract todos |
| Messages | Share an iMessage → extract "I'll do X by Friday" |
| Safari | Share an article → extract research tasks |

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| No text selected, user shares a URL | Extract page title as a task hint; show URL as context |
| Text is very long (>2000 words) | Truncate to first 2000 chars; show warning "Summarizing first 2000 characters" |
| Apple Intelligence not available | Fall back to regex parser; still extracts obvious action verbs |
| Zero tasks found | Show "No tasks found in this text" with option to add manually |

### Technical Notes

- iOS Share Extension target in Xcode (separate bundle, same App Group for SwiftData access)
- App Group required to share the SwiftData store between the extension and the main app
- Extension UI is a `UIViewController` presented as a sheet — keep it minimal (preview + one button)
- Same `AIParsingManager` code path, shared via a framework or direct file inclusion

---

## Feature 3: EventKit Integration — Write to Apple Calendar and Reminders

**Priority:** P1  
**Effort:** Medium (2–4 days)

### Problem

Tasks in Voxdump exist only inside Voxdump. A user who says "dentist appointment Thursday at 2pm" expects to see that on their calendar. Today it creates a Voxdump task but nothing appears in Calendar or Reminders — where the user actually lives.

### Solution

After a task is accepted in the review flow, offer to sync it to Apple's native apps via EventKit.

### UX — Per-Task

At the task review card (the "1 of 4" swipe screen):

- If the task has a **specific time** ("dentist at 2pm Thursday") → offer "Add to Calendar"
- If the task has a **date but no time** ("pay rent by Friday") → offer "Add to Reminders"
- If the task has **no date** → add to Voxdump only (no Calendar/Reminders prompt)

The offer is a small toggle on the review card, not a modal. Default is off; user opts in per task.

### UX — Settings

A global preference: "Always sync to Apple Reminders / Calendar / Neither"  
When set, skips the per-task toggle and syncs automatically.

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| EventKit permission denied | Show "Grant Calendar access in Settings" prompt once; don't nag |
| Duplicate detection | Check for existing event with same title ±1 day before creating |
| Task edited after sync | Update is one-way (Voxdump → Calendar); changes in Calendar do not sync back |
| Task deleted in Voxdump | Do not delete the Calendar event; they are independent after creation |

### Technical Notes

- `EventKit` framework — `EKEventStore` for Calendar, `EKReminder` for Reminders
- Request `.event` permission for Calendar, `.reminder` permission for Reminders
- Store the `EKEvent.eventIdentifier` in SwiftData so duplicates can be detected
- One-way sync only (Voxdump as source of truth)

---

## Feature 4: Meeting Mode (Granola-style Long-Form Recording)

**Priority:** P2  
**Effort:** High (1–2 weeks)

### Problem

Meetings generate the most tasks of anything in a professional's day. Today Voxdump records short bursts (ends on silence). For meetings, users need continuous 30–90 minute recording with task extraction after.

### Why this matters

Granola — the closest product to this — costs $18/month, requires a Mac, and sends audio to a server. Voxdump can do the same thing on iPhone, on-device, for free. That is a meaningful differentiation.

### Solution

A second recording mode: **Meeting Mode**. User starts it before a meeting, leaves it running, ends it when done. The full transcript is processed by Apple Intelligence to extract tasks, decisions, and follow-up items.

### UX Flow

```
Home screen
    ↓ Long-press (or new "Meeting" button) on the mic
[Meeting Mode starts]
    → Status bar shows recording indicator
    → Minimized UI: timer + "End Meeting" button
    → App can be backgrounded (recording continues)
[During meeting — live rolling transcript visible if app is foregrounded]
[User taps "End Meeting"]
    ↓ Recording stops
    ↓ Full transcript shown briefly
    ↓ Apple Intelligence processes (~15–30 sec for 1hr meeting)
[Results screen — different from standard task review]
    Section 1: Action Items (tasks with owners/dates if spoken)
    Section 2: Decisions Made
    Section 3: Follow-ups ("we should look into X")
    → User reviews, accepts/dismisses each item
[Accepted items saved to Voxdump task list]
[Option to export full transcript to Apple Notes]
```

### UX Differences from Standard Mode

| | Standard Mode | Meeting Mode |
|--|--------------|--------------|
| Recording length | 10–30 seconds | 30–90 minutes |
| Ends on | Silence detection | Manual "End Meeting" tap |
| Background | No | Yes |
| Output | Task list | Action items + Decisions + Follow-ups |
| Review UI | Single card per task | Grouped sections |
| Transcript | Not shown | Shown, exportable |

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| App killed mid-meeting | Save transcript chunks to disk as they arrive; resume on relaunch |
| Recording > 2 hours | Warn at 90 minutes; stop automatically at 3 hours |
| Apple Intelligence timeout on large transcript | Chunk transcript into 5-min segments, process each, merge results |
| Multiple speakers | No speaker diarization (too complex for v1); transcribe as one voice |
| Poor audio / cross-talk | Transcription quality degrades; surface confidence score, let user edit |

### Technical Notes

- `SFSpeechRecognizer` has a ~1-minute hard limit per recognition request
- Chunking strategy: start a new recognition request every 55 seconds, append results
- Background audio requires `UIBackgroundModes: audio` in Info.plist and `AVAudioSession.Category.record`
- Store chunks in a temporary file; assemble full transcript on session end
- Apple Intelligence parsing: split transcript into 5-minute windows, process in parallel, deduplicate merged results

---

## Feature 5: iCloud Sync

**Priority:** P2  
**Effort:** Medium (3–5 days)

### Problem

Tasks captured on iPhone are not visible on iPad or Mac. Users who switch devices lose context.

### Solution

Use CloudKit (free, no backend required) to sync the SwiftData store across the user's devices.

### Notes

- SwiftData has native CloudKit integration via `ModelConfiguration(cloudKitContainerIdentifier:)`
- Requires an iCloud container registered in App Store Connect (free)
- Conflict resolution: last-write-wins on task completion status; merge on task creation
- This is the only feature that requires internet connectivity — all others work fully offline

---

## Feature 6: Lock Screen Widget + Dynamic Island

**Priority:** P3  
**Effort:** Small (1–2 days)

### Problem

The fastest path to capturing a thought is not opening an app. A Lock Screen widget that launches directly into voice recording removes one more tap.

### Solution

- **Lock Screen widget**: single button that deep-links into Voxdump recording mode via App Intent
- **Dynamic Island**: when recording is active, show a mic indicator in the Dynamic Island so the user knows recording is live without unlocking

---

## Phasing

### v1.1 — Fix what's broken
- Fix end-to-end reminders (Feature 1)

### v1.2 — Expand the capture surface
- Share Extension (Feature 2)
- EventKit sync (Feature 3)

### v1.3 — New use case
- Meeting Mode (Feature 4)

### v1.4 — Polish and reach
- iCloud sync (Feature 5)
- Lock Screen widget (Feature 6)

---

## Open Questions for PM

1. **Meeting Mode scope**: Should v1 of Meeting Mode include Decisions and Follow-ups sections, or just Action Items? Simpler = faster to ship.
2. **EventKit default**: Should sync to Calendar/Reminders be opt-in per task (more control) or a single global toggle (less friction)?
3. **Share Extension branding**: Should the extension be called "Voxdump" or something more descriptive like "Extract Tasks"?
4. **Transcript export**: Should Meeting Mode export the full transcript to Apple Notes automatically, or only on user request?
5. **Long-form recording on non-AI devices**: Meeting Mode without Apple Intelligence falls back to the regex parser, which will miss most action items from natural meeting speech. Is that acceptable, or should Meeting Mode be AI-gated?
