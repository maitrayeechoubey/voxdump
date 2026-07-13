import SwiftUI

/// In-app regression suite for the transcript → task pipeline, covering the same
/// scenarios as the manual QA pass. Runs against both FoundationModels (when available)
/// and FallbackParser directly, so the fallback path — which real devices without Apple
/// Intelligence hit, but the simulator never does — actually gets exercised.
struct EvalCase: Identifiable {
    let id = UUID()
    let name: String
    let transcript: String
    /// Given the ParsedDump result (nil if the transcript short-circuited before parsing,
    /// e.g. a stop-phrase), return (pass, detail).
    let check: (ParsedDump?) -> (Bool, String)

    static let suite: [EvalCase] = [
        EvalCase(name: "S1 Single task", transcript: "I need to call the dentist to schedule a cleaning") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == nil && !r.tasks.isEmpty, "tasks=\(r.tasks.count) command=\(String(describing: r.command))")
        },
        EvalCase(name: "S2 Multi task", transcript: "I need to pay my electric bill and also pick up dry cleaning") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == nil && r.tasks.count == 2, "tasks=\(r.tasks.count) titles=\(r.tasks.map(\.title))")
        },
        EvalCase(name: "S3 Stop phrase only", transcript: "that's it") { r in
            // The real app never even calls parse() for this — TranscriptFilter.isStopOnly
            // short-circuits it. r should be nil here.
            (r == nil, r == nil ? "correctly short-circuited, no task created" : "did NOT short-circuit: \(String(describing: r))")
        },
        EvalCase(name: "S4 Task + trailing stop phrase", transcript: "remind me to schedule a haircut, that's it") { r in
            guard let r else { return (false, "short-circuited before parsing (should have produced a task)") }
            // The bug class we're guarding against: total silent loss. Either a real task
            // was extracted, or a reminder command carries a non-empty hint that ContentView
            // will convert into a task. Anything else is a silent drop.
            let hasTask = !r.tasks.isEmpty
            let hasUsableReminder: Bool = {
                if case .scheduleReminder(let hint, _) = r.command { return !(hint ?? "").isEmpty }
                return false
            }()
            return (hasTask || hasUsableReminder, "tasks=\(r.tasks.count) command=\(String(describing: r.command))")
        },
        EvalCase(name: "S5 Self-correction", transcript: "remind me to call AT&T, actually change it to Xfinity") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            let ok = r.command == nil && r.tasks.count == 1
                && r.tasks.first!.title.lowercased().contains("xfinity")
                && !r.tasks.first!.title.lowercased().contains("at&t")
            return (ok, "tasks=\(r.tasks.map(\.title))")
        },
        EvalCase(name: "S6 Clear all tasks", transcript: "clear all tasks") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == .deleteAll, "command=\(String(describing: r.command))")
        },
        EvalCase(name: "S7 Mark all done and clear", transcript: "mark all done and clear") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == .completeAndClear, "command=\(String(describing: r.command))")
        },
        EvalCase(name: "S8 Multi task with continuation", transcript: "buy groceries and also call mom") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == nil && r.tasks.count == 2, "tasks=\(r.tasks.map(\.title))")
        },
        EvalCase(name: "S9 Complete N happy path", transcript: "I finished 2 tasks") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == .completeN(2), "command=\(String(describing: r.command))")
        },
        EvalCase(name: "S10 Complete N overflow", transcript: "mark 10 tasks done") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == .completeN(10), "command=\(String(describing: r.command))")
        },
        EvalCase(name: "S11 Delete completed only", transcript: "clear the completed ones") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == .deleteCompleted, "command=\(String(describing: r.command))")
        },
        EvalCase(name: "S12 Show tasks navigation", transcript: "show my tasks") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == .showTasks, "command=\(String(describing: r.command))")
        },
        EvalCase(name: "S18 Numbers in task titles", transcript: "I need to read chapter 12 of the handbook and submit form I-9 by Friday") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            let noCommand = r.command == nil
            return (noCommand && r.tasks.count == 2, "command=\(String(describing: r.command)) tasks=\(r.tasks.map(\.title))")
        },
        EvalCase(name: "S19 URL and email preserved", transcript: "update the README at github.com/org/repo and email the summary to team@company.com") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            let preserved = r.tasks.contains { $0.title.lowercased().contains("github.com/org/repo") || ($0.originalQuote?.lowercased().contains("github.com/org/repo") ?? false) }
                && r.tasks.contains { $0.title.lowercased().contains("team@company.com") || ($0.originalQuote?.lowercased().contains("team@company.com") ?? false) }
            return (r.command == nil && r.tasks.count == 2 && preserved, "tasks=\(r.tasks.map(\.title))")
        },
        EvalCase(name: "S20 Emoji in transcript", transcript: "buy birthday cake 🎂 for mom and wrap the gift 🎁") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == nil && r.tasks.count == 2, "tasks=\(r.tasks.map(\.title))")
        },
        EvalCase(name: "S21 Non-English + diacritics", transcript: "call Abuela about the cena de Navidad and buy pan dulce from the panadería") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            let preservedDiacritic = r.tasks.contains { $0.title.contains("panadería") || ($0.originalQuote?.contains("panadería") ?? false) }
            return (r.command == nil && r.tasks.count == 2 && preservedDiacritic, "tasks=\(r.tasks.map(\.title))")
        },
        EvalCase(name: "S22 Long transcript (200+ words)", transcript: """
            Okay so um, let me think, there's a bunch of stuff on my mind, you know. First off I need to \
            call the insurance company about the claim they denied last week, that's been sitting there \
            forever and I keep forgetting, um, and you know I also have to pick up my dry cleaning \
            because I have that event on Saturday and I have literally nothing to wear otherwise, wait I \
            also need to email my manager about the timeline slip on the migration project because I \
            promised an update by end of week and I have not sent it yet, oh and another thing, I need to \
            schedule a dentist appointment because my tooth has been bothering me for like two weeks now \
            and I keep putting it off, anyway yeah I think that's most of it, um, just those four things \
            really, call insurance, dry cleaning, email manager, dentist appointment, that's the list.
            """) { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == nil && r.tasks.count == 4, "tasks=\(r.tasks.map(\.title))")
        },
        EvalCase(name: "S23 Ambiguous complete-all phrasing", transcript: "done with everything") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == .completeAll, "command=\(String(describing: r.command))")
        },
        EvalCase(name: "S24 Multi-step correction chain", transcript: "remind me to call AT&T, actually no, email AT&T, wait scratch that, just text John about the AT&T bill") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            let ok = r.tasks.count == 1 && r.tasks.first!.title.lowercased().contains("text john")
            return (ok, "tasks=\(r.tasks.map(\.title)) command=\(String(describing: r.command))")
        },
        EvalCase(name: "S26 Stop phrase, mixed case + punctuation", transcript: "That's It.") { r in
            (r == nil, r == nil ? "correctly short-circuited, no task created" : "did NOT short-circuit: \(String(describing: r))")
        },
        EvalCase(name: "S34a Fallback: read today", transcript: "what's due today") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == .readTasks(.today), "command=\(String(describing: r.command))")
        },
        EvalCase(name: "S34b Fallback: read pending", transcript: "what's left") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == .readTasks(.pending), "command=\(String(describing: r.command))")
        },
        EvalCase(name: "S34c Fallback: read all", transcript: "read everything") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            return (r.command == .readTasks(.all), "command=\(String(describing: r.command))")
        },
        EvalCase(name: "S34d Fallback: schedule reminder", transcript: "remind me to call the dentist at 3pm") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .scheduleReminder(let hint, _) = r.command {
                return (!(hint ?? "").isEmpty, "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) (expected .scheduleReminder)")
        },
        EvalCase(name: "S36 Complete-named happy path", transcript: "mark the dentist task as done") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .completeNamed(let hint) = r.command {
                return (hint.lowercased().contains("dentist"), "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) (expected .completeNamed containing \"dentist\")")
        },
        EvalCase(name: "S37 Complete-named via \"I finished X\" phrasing", transcript: "I finished grocery shopping") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .completeNamed(let hint) = r.command {
                return (hint.lowercased().contains("grocery"), "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) (expected .completeNamed containing \"grocery\")")
        },
        EvalCase(name: "S38 Named-vs-numeric collision: \"mark task 2 as done\"", transcript: "mark task 2 as done") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            // Desired: this names a specific task ("task 2"), not a bulk count. If the parser
            // reads the digit and returns .completeN(2) instead, it silently completes the
            // wrong task(s) — the most-recent-2-by-createdAt, not the one literally named "task 2".
            if case .completeNamed = r.command {
                return (true, "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) — collided with numeric completeN parsing instead of treating \"task 2\" as a name")
        },
        EvalCase(name: "S39 Delete-named: \"clear the dentist task\"", transcript: "clear the dentist task") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .deleteNamed(let hint) = r.command {
                return (hint.lowercased().contains("dentist"), "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) tasks=\(r.tasks.map(\.title)) (expected .deleteNamed containing \"dentist\")")
        },
        EvalCase(name: "S40 Reactivate-named: \"undo completing the dentist task\"", transcript: "undo completing the dentist task") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .reactivateNamed(let hint) = r.command {
                return (hint.lowercased().contains("dentist"), "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) tasks=\(r.tasks.map(\.title)) (expected .reactivateNamed containing \"dentist\")")
        },
        EvalCase(name: "S40b Reactivate-named: \"mark the dentist task as not done\"", transcript: "mark the dentist task as not done") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .reactivateNamed(let hint) = r.command {
                return (hint.lowercased().contains("dentist"), "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) tasks=\(r.tasks.map(\.title)) (expected .reactivateNamed containing \"dentist\")")
        },
        EvalCase(name: "S41 Fallback: complete-named prefix coverage", transcript: "complete my call with John") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .completeNamed(let hint) = r.command {
                return (hint.lowercased().contains("call with john") || hint.lowercased().contains("john"), "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) (expected .completeNamed containing \"john\")")
        },
        EvalCase(name: "S42 Complete-named via past-tense narration", transcript: "I have called xfinity today, so you can mark the task as done") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .completeNamed(let hint) = r.command {
                return (hint.lowercased().contains("xfinity"), "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) tasks=\(r.tasks.map(\.title)) (expected .completeNamed containing \"xfinity\", NOT task_creation)")
        },
        EvalCase(name: "S43 Complete-named: past-tense rent, check it off", transcript: "I already paid the rent, check it off") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .completeNamed(let hint) = r.command {
                return (hint.lowercased().contains("rent"), "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) tasks=\(r.tasks.map(\.title)) (expected .completeNamed containing \"rent\")")
        },
        EvalCase(name: "S44 Reactivate-named via \"reopen the dentist task\"", transcript: "reopen the dentist task") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .reactivateNamed(let hint) = r.command {
                return (hint.lowercased().contains("dentist"), "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) tasks=\(r.tasks.map(\.title)) (expected .reactivateNamed containing \"dentist\", NOT task_creation)")
        },
        EvalCase(name: "S45 Reactivate-named: verb inside name \"reopen create demo app task\"", transcript: "reopen create demo app task") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .reactivateNamed(let hint) = r.command {
                let h = hint.lowercased()
                return (h.contains("demo") || h.contains("app"), "command=\(String(describing: r.command))")
            }
            return (false, "command=\(String(describing: r.command)) tasks=\(r.tasks.map(\.title)) (expected .reactivateNamed, NOT task_creation — 'create' is part of the name)")
        },
        EvalCase(name: "S46 Reactivate-all: \"reopen all the done tasks\"", transcript: "reopen all the done tasks") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .reactivateAll = r.command { return (true, "command=\(String(describing: r.command))") }
            return (false, "command=\(String(describing: r.command)) tasks=\(r.tasks.map(\.title)) (expected .reactivateAll, NOT complete_all — reopen is the opposite)")
        },
        EvalCase(name: "S47 Reactivate-all: \"mark all tasks as not done\"", transcript: "mark all tasks as not done") { r in
            guard let r else { return (false, "short-circuited before parsing") }
            if case .reactivateAll = r.command { return (true, "command=\(String(describing: r.command))") }
            return (false, "command=\(String(describing: r.command)) tasks=\(r.tasks.map(\.title)) (expected .reactivateAll, NOT complete_all)")
        },
    ]
}

extension ParsedDump.VoiceCommand.ReadFilter: Equatable {
    static func == (lhs: ParsedDump.VoiceCommand.ReadFilter, rhs: ParsedDump.VoiceCommand.ReadFilter) -> Bool {
        switch (lhs, rhs) {
        case (.today, .today), (.pending, .pending), (.all, .all): return true
        default: return false
        }
    }
}

extension ParsedDump.VoiceCommand: Equatable {
    static func == (lhs: ParsedDump.VoiceCommand, rhs: ParsedDump.VoiceCommand) -> Bool {
        switch (lhs, rhs) {
        case (.completeAll, .completeAll), (.completeAndClear, .completeAndClear),
             (.deleteAll, .deleteAll), (.deleteCompleted, .deleteCompleted), (.showTasks, .showTasks):
            return true
        case (.completeN(let a), .completeN(let b)): return a == b
        case (.completeNamed(let a), .completeNamed(let b)): return a == b
        case (.deleteNamed(let a), .deleteNamed(let b)): return a == b
        case (.reactivateNamed(let a), .reactivateNamed(let b)): return a == b
        case (.readTasks(let a), .readTasks(let b)): return a == b
        case (.scheduleReminder(let h1, let t1), .scheduleReminder(let h2, let t2)): return h1 == h2 && t1 == t2
        default: return false
        }
    }
}

struct EvalResult: Identifiable {
    let id = UUID()
    let name: String
    let transcript: String
    let mode: String
    let pass: Bool
    let detail: String
}

@MainActor
final class EvalRunner: ObservableObject {
    @Published var results: [EvalResult] = []
    @Published var isRunning = false

    private func run(_ transcript: String, forceFallback: Bool) async -> (ParsedDump?, String) {
        if TranscriptFilter.isStopOnly(transcript) { return (nil, "n/a — short-circuited") }
        if forceFallback {
            let lower = transcript.lowercased()
            if let command = FallbackParser.detectCommand(from: lower) {
                return (ParsedDump(tasks: [], command: command), "FallbackParser (forced)")
            }
            return (FallbackParser.parse(transcript: transcript), "FallbackParser (forced)")
        }
        let ai = AIParsingManager()
        let result = try? await ai.parse(transcript: transcript)
        let mode = ai.parsingMode == .foundationModels ? "FoundationModels" : "FallbackParser"
        return (result, mode)
    }

    func runAll(forceFallback: Bool) async {
        isRunning = true
        results = []
        for c in EvalCase.suite {
            let (dump, mode) = await run(c.transcript, forceFallback: forceFallback)
            let (pass, detail) = c.check(dump)
            results.append(EvalResult(name: c.name, transcript: c.transcript, mode: mode, pass: pass, detail: detail))
        }
        isRunning = false
    }
}

struct EvalRunnerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = EvalRunner()
    @State private var forceFallback = false

    private var passCount: Int { runner.results.filter(\.pass).count }

    var body: some View {
        ZStack {
            Color.bdBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                            Text("Back").font(.bdCaption())
                        }
                        .foregroundStyle(Color.bdMuted)
                    }
                    Spacer()
                    Text("QA Eval").font(.bdBody()).foregroundStyle(.white)
                    Spacer()
                    Text("Back").font(.bdCaption()).opacity(0)
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)

                Toggle(isOn: $forceFallback) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Force FallbackParser").font(.bdBody()).foregroundStyle(.white)
                        Text("Bypasses FoundationModels — exercises the code path most real devices without Apple Intelligence actually use.")
                            .font(.system(size: 12)).foregroundStyle(Color.bdMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)

                Button {
                    Task { await runner.runAll(forceFallback: forceFallback) }
                } label: {
                    Text(runner.isRunning ? "Running…" : "Run All \(EvalCase.suite.count) Scenarios")
                        .font(.bdBody().bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.bdPrimary))
                        .foregroundStyle(.white)
                }
                .disabled(runner.isRunning)
                .padding(.horizontal, 20).padding(.bottom, 12)

                if !runner.results.isEmpty {
                    Text("\(passCount) / \(runner.results.count) passed")
                        .font(.bdCaption())
                        .foregroundStyle(passCount == runner.results.count ? Color.bdGreen : Color.bdMuted)
                        .padding(.bottom, 8)
                }

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(runner.results) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: r.pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(r.pass ? Color.bdGreen : .red)
                                    Text(r.name).font(.bdBody().bold()).foregroundStyle(.white)
                                    Spacer()
                                    Text(r.mode).font(.system(size: 11)).foregroundStyle(Color.bdMuted2)
                                }
                                Text("\"\(r.transcript)\"").font(.system(size: 12)).foregroundStyle(Color.bdMuted)
                                Text(r.detail).font(.system(size: 12)).foregroundStyle(Color.bdMuted)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.bdCard))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.bdBorder, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .navigationBarHidden(true)
    }
}
