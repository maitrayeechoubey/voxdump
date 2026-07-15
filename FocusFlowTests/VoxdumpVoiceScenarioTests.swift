import XCTest
import SwiftData
@testable import FocusFlow

// MARK: - VoxdumpVoiceScenarioTests
// The everyday voice QA net. Each scenario reads like a spoken interaction:
//
//     Scenario("complete the second task",
//              seed: [.pending("Water plants"), .pending("Buy groceries"), .pending("Call mom")],
//              say: "complete the second task",
//              expect: .completes(["Buy groceries"]))
//
// The runner seeds an in-memory SwiftData store and drives the REAL pipeline the app uses on the
// Tasks list — NavCommandMatcher -> TaskSnapshot (in @Query display order) -> NavCommandResolver ->
// map to TaskItems -> apply the mutation (with BulkDeleteConfirmMatcher for deletes) -> assert the
// resulting store. This exercises everything AFTER the transcript string, which is where every
// device-reported bug lived. Only the mic + Apple speech-to-text stay device-only (and they are not
// where the bugs are). Runs in well under a second; add a case by appending one line.
//
// To grow coverage from real usage: run `scripts/harvest_transcripts.py` on a device logarchive to
// turn each real (often garbled) utterance into a scenario. See docs/qa-voice-testing.md.

@MainActor
final class VoxdumpVoiceScenarioTests: XCTestCase {

    // MARK: Scenario model

    struct Seed {
        let title: String; let completed: Bool; let daysAgo: Int
        static func pending(_ t: String, daysAgo: Int = 0) -> Seed { .init(title: t, completed: false, daysAgo: daysAgo) }
        static func done(_ t: String, daysAgo: Int = 0) -> Seed { .init(title: t, completed: true, daysAgo: daysAgo) }
    }

    enum Expect: Equatable {
        case completes([String])   // these titles end up completed (and no others change)
        case reopens([String])     // these completed titles become pending
        case deletes([String])     // these titles are removed after the confirm reply is applied
        case opens(String)         // resolves to opening exactly this title
        case newDump, readAloud, goBack, mute
        case noMatch               // matcher returns nil — nothing happens
        case notFound              // a verb matched but resolved to zero tasks — nothing changes
    }

    struct Scenario {
        let say: String
        let seed: [Seed]
        let expect: Expect
        let confirm: String?       // spoken reply to a delete confirmation ("yes"/"no"/…)
        init(_ say: String, seed: [Seed], expect: Expect, confirm: String? = nil) {
            self.say = say; self.seed = seed; self.expect = expect; self.confirm = confirm
        }
    }

    // MARK: The scenarios (append freely)

    private func scenarios() -> [Scenario] {
        let three: [Seed] = [.pending("Water plants"), .pending("Buy groceries", daysAgo: 1), .pending("Call mom", daysAgo: 2)]
        return [
            // --- Ordinals (bug 3) ---
            Scenario("mark the first", seed: three, expect: .completes(["Water plants"])),
            Scenario("complete the second task", seed: three, expect: .completes(["Buy groceries"])),
            Scenario("finish the third one", seed: three, expect: .completes(["Call mom"])),
            Scenario("complete the last task", seed: three, expect: .completes(["Call mom"])),
            Scenario("mark the 2nd task done", seed: three, expect: .completes(["Buy groceries"])),
            Scenario("complete task 5", seed: three, expect: .notFound),   // out of range, nothing happens

            // --- Bulk all (bugs 4 & 7) ---
            Scenario("complete all", seed: three, expect: .completes(["Water plants", "Buy groceries", "Call mom"])),
            Scenario("mark everything as done", seed: three, expect: .completes(["Water plants", "Buy groceries", "Call mom"])),

            // --- Date-scoped (bug 3) ---
            Scenario("complete all tasks created yesterday",
                     seed: [.pending("Water plants", daysAgo: 0), .pending("Buy groceries", daysAgo: 1), .pending("Call mom", daysAgo: 1)],
                     expect: .completes(["Buy groceries", "Call mom"])),

            // --- Name (fuzzy) ---
            Scenario("complete buy groceries", seed: three, expect: .completes(["Buy groceries"])),
            Scenario("finish the call mom task", seed: three, expect: .completes(["Call mom"])),

            // --- Name-before-verb ---
            Scenario("call mom is done", seed: three, expect: .completes(["Call mom"])),
            Scenario("buy groceries done", seed: three, expect: .completes(["Buy groceries"])),

            // --- Open (bug 6): earliest verb wins; pending preferred ---
            Scenario("open remove sumit paperwork",
                     seed: [.pending("Water plants"), .pending("Remove sumit paperwork")],
                     expect: .opens("Remove sumit paperwork")),
            Scenario("open call mom", seed: three, expect: .opens("Call mom")),
            Scenario("open call plumber",
                     seed: [.done("Call plumber", daysAgo: 1), .pending("Call plumber")],
                     expect: .opens("Call plumber")),   // prefers the pending one (see resolver test for identity)

            // --- Complete never touches a completed task (bug 6) ---
            Scenario("complete call plumber",
                     seed: [.done("Call plumber"), .pending("Water plants")],
                     expect: .notFound),

            // --- Reopen ---
            Scenario("reopen call plumber",
                     seed: [.done("Call plumber"), .pending("Water plants")],
                     expect: .reopens(["Call plumber"])),

            // --- Delete + confirm (bug 4) ---
            Scenario("clear all", seed: three, expect: .deletes(["Water plants", "Buy groceries", "Call mom"]), confirm: "yes"),
            Scenario("clear all", seed: three, expect: .deletes([]), confirm: "no"),                 // "no" keeps everything
            Scenario("clear all", seed: three, expect: .deletes(["Water plants", "Buy groceries", "Call mom"]), confirm: "yeah go for it"),
            Scenario("delete buy groceries", seed: three, expect: .deletes(["Buy groceries"]), confirm: "yes please delete"),
            Scenario("delete the first task", seed: three, expect: .deletes(["Water plants"]), confirm: "yes"),

            // --- Navigation verbs ---
            Scenario("new task", seed: three, expect: .newDump),
            Scenario("add another task", seed: three, expect: .newDump),
            Scenario("read my tasks", seed: three, expect: .readAloud),
            Scenario("go home", seed: three, expect: .goBack),
            Scenario("mute", seed: three, expect: .mute),

            // --- Real garbled device transcripts route sanely (or safely do nothing) ---
            Scenario("Complete all", seed: three, expect: .completes(["Water plants", "Buy groceries", "Call mom"])),
            Scenario("Mark the first", seed: three, expect: .completes(["Water plants"])),
            Scenario("Create a new task", seed: three, expect: .newDump),
            Scenario("Yesi Tu Asi Ho office Main Hoon Ki", seed: three, expect: .noMatch),   // gibberish must do nothing
            Scenario("Call plumber has done", seed: [.pending("Call plumber")], expect: .completes(["Call plumber"]))
        ]
    }

    // MARK: Runner

    func test_allScenarios() throws {
        for s in scenarios() {
            try runScenario(s)
        }
    }

    private func runScenario(_ s: Scenario) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TaskItem.self, MicroStep.self, configurations: config)
        let ctx = container.mainContext
        for seed in s.seed {
            let t = TaskItem(title: seed.title)
            t.isCompleted = seed.completed
            t.createdAt = Calendar.current.date(byAdding: .day, value: -seed.daysAgo, to: Date())!
            ctx.insert(t)
        }

        let label = "[\(s.say)]"
        let cmd = NavCommandMatcher.match(s.say)

        // Resolve the same way AllTasksView does.
        func allTasks() -> [TaskItem] {
            ((try? ctx.fetch(FetchDescriptor<TaskItem>())) ?? []).sorted { $0.createdAt > $1.createdAt }
        }
        func targets(_ c: NavCommand) -> [TaskItem] {
            let tasks = allTasks()
            let snap = tasks.map { TaskSnapshot(title: $0.title, isCompleted: $0.isCompleted, createdAt: $0.createdAt) }
            return NavCommandResolver.resolve(c, in: snap, now: Date()).map { tasks[$0] }
        }

        switch s.expect {
        case .noMatch:
            XCTAssertNil(cmd, "\(label) should not match any command")

        case .newDump:   XCTAssertEqual(cmd, .newDump, label)
        case .readAloud: XCTAssertEqual(cmd, .readTasks, label)
        case .goBack:    XCTAssertEqual(cmd, .goBack, label)
        case .mute:      XCTAssertEqual(cmd, .mute, label)

        case .opens(let title):
            guard let cmd else { return XCTFail("\(label) expected open, got no match") }
            let t = targets(cmd)
            XCTAssertEqual(t.first?.title, title, "\(label) should open ‘\(title)’")

        case .notFound:
            guard let cmd else { return XCTFail("\(label) expected a verb match, got nil") }
            XCTAssertTrue(targets(cmd).isEmpty, "\(label) should resolve to no task")

        case .completes(let titles):
            guard let cmd else { return XCTFail("\(label) expected complete, got nil") }
            targets(cmd).forEach { $0.isCompleted = true }
            let done = Set(allTasks().filter { $0.isCompleted }.map { $0.title })
            XCTAssertEqual(done, Set(titles), "\(label) completed set mismatch")

        case .reopens(let titles):
            guard let cmd else { return XCTFail("\(label) expected reopen, got nil") }
            targets(cmd).forEach { $0.isCompleted = false }
            let stillDone = Set(allTasks().filter { $0.isCompleted }.map { $0.title })
            for t in titles { XCTAssertFalse(stillDone.contains(t), "\(label) ‘\(t)’ should be reopened") }

        case .deletes(let titles):
            guard let cmd else { return XCTFail("\(label) expected delete, got nil") }
            let toDelete = targets(cmd)
            let verdict = s.confirm.flatMap { BulkDeleteConfirmMatcher.match($0) }
            if verdict == .confirm { toDelete.forEach { ctx.delete($0) } }
            let remaining = Set(allTasks().map { $0.title })
            let seededTitles = Set(s.seed.map { $0.title })
            let expectedRemaining = seededTitles.subtracting(titles)
            XCTAssertEqual(remaining, expectedRemaining,
                           "\(label) confirm=\(s.confirm ?? "nil") remaining mismatch")
        }
    }
}
