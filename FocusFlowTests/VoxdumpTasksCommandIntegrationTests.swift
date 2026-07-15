import XCTest
import SwiftData
@testable import FocusFlow

// MARK: - VoxdumpTasksCommandIntegrationTests
// End-to-end proof of the Tasks-list voice commands against a REAL in-memory SwiftData store,
// driving the exact path AllTasksView uses: NavCommandMatcher -> snapshot (in @Query display
// order) -> NavCommandResolver -> map back to TaskItems -> apply the mutation. This validates the
// glue (snapshot building, index mapping, pending-vs-completed universe, bulk mutation) that unit
// tests on the pure types can't reach. Deterministic, in-process, no mic, no simulator UI.
// Each test reproduces a specific device-reported bug from 2026-07-14.

@MainActor
final class VoxdumpTasksCommandIntegrationTests: XCTestCase {
    private var container: ModelContainer!
    private var ctx: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: TaskItem.self, MicroStep.self, configurations: config)
        ctx = container.mainContext
    }
    override func tearDown() { container = nil; ctx = nil; super.tearDown() }

    @discardableResult
    private func seed(_ title: String, completed: Bool = false, daysAgo: Int = 0) -> TaskItem {
        let t = TaskItem(title: title)
        t.isCompleted = completed
        t.createdAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        ctx.insert(t)
        return t
    }

    /// Mirrors AllTasksView's @Query(sort: createdAt, order: .reverse): most-recent first.
    private func allTasks() -> [TaskItem] {
        ((try? ctx.fetch(FetchDescriptor<TaskItem>())) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    private func resolve(_ transcript: String) -> (cmd: NavCommand?, targets: [TaskItem]) {
        guard let cmd = NavCommandMatcher.match(transcript) else { return (nil, []) }
        let tasks = allTasks()
        let snap = tasks.map { TaskSnapshot(title: $0.title, isCompleted: $0.isCompleted, createdAt: $0.createdAt) }
        let idx = NavCommandResolver.resolve(cmd, in: snap, now: Date())
        return (cmd, idx.map { tasks[$0] })
    }

    /// Applies the same effect AllTasksView.perform does.
    private func perform(_ transcript: String) {
        let (cmd, targets) = resolve(transcript)
        guard let cmd else { return }
        switch cmd {
        case .complete: targets.forEach { $0.isCompleted = true }
        case .reopen:   targets.forEach { $0.isCompleted = false }
        case .delete:   targets.forEach { ctx.delete($0) }
        default: break
        }
    }

    // bug 7 — "of all tasks I asked to complete, it only completed 1"
    func test_completeAll_marksEveryPendingDone() {
        seed("Water plants"); seed("Buy groceries"); seed("Call mom")
        perform("complete all")
        XCTAssertEqual(allTasks().filter { !$0.isCompleted }.count, 0,
                       "‘complete all’ must complete every pending task, not just one")
    }

    // bug 3 — "complete 2nd task does nothing"
    func test_completeSecond_marksOnlySecond() {
        let first  = seed("Water plants", daysAgo: 0)   // newest -> position 1
        let second = seed("Buy groceries", daysAgo: 1)  // position 2
        let third  = seed("Call mom", daysAgo: 2)        // position 3
        perform("complete the second task")
        XCTAssertFalse(first.isCompleted)
        XCTAssertTrue(second.isCompleted, "the second task should be the one completed")
        XCTAssertFalse(third.isCompleted)
    }

    // bug 4 — "clear all asks yes/no but won't accept yes"
    func test_clearAll_thenYes_deletesEverything() {
        seed("Water plants"); seed("Buy groceries"); seed("Old thing", completed: true)
        let (cmd, targets) = resolve("clear all")
        XCTAssertEqual(cmd, .delete(.all))
        XCTAssertEqual(targets.count, 3, "‘clear all’ must target the whole list")
        XCTAssertEqual(BulkDeleteConfirmMatcher.match("yes"), .confirm)      // the confirm now accepts "yes"
        targets.forEach { ctx.delete($0) }
        XCTAssertEqual(allTasks().count, 0)
    }

    // bug 6 — "open opens the COMPLETED task instead of the one I meant"
    func test_openName_prefersPendingOverCompletedNamesake() {
        let donePlumber    = seed("Call plumber", completed: true, daysAgo: 1)
        let pendingPlumber = seed("Call plumber", daysAgo: 0)   // same name, still pending
        let (_, targets) = resolve("open call plumber")
        XCTAssertEqual(targets.first, pendingPlumber, "open must prefer the pending task")
        XCTAssertNotEqual(targets.first, donePlumber)
    }

    // bug 6 — completing by a name that only matches a completed task must do nothing.
    func test_completeName_completedOnly_resolvesEmpty() {
        seed("Call plumber", completed: true)
        let pending = seed("Water plants")
        let (cmd, targets) = resolve("complete call plumber")
        XCTAssertEqual(cmd, .complete(.name("call plumber")))
        XCTAssertTrue(targets.isEmpty, "complete targets pending only; a completed-only name resolves to nothing")
        XCTAssertFalse(pending.isCompleted)
    }

    // bug 6 — "open remove sumit paperwork did nothing"
    func test_openMultiwordName_targetsThatTask() {
        seed("Water plants")
        seed("Remove sumit paperwork")
        let (cmd, targets) = resolve("open remove sumit paperwork")
        if case .open = cmd {} else { return XCTFail("expected open, got \(String(describing: cmd))") }
        XCTAssertEqual(targets.first?.title, "Remove sumit paperwork",
                       "earliest verb wins: this opens the task named ‘remove sumit paperwork’")
    }

    // bug 3 — "complete all tasks created yesterday does nothing"
    func test_completeCreatedYesterday_onlyYesterdaysPending() {
        let today = seed("Water plants", daysAgo: 0)
        let y1 = seed("Buy groceries", daysAgo: 1)
        let y2 = seed("Call mom", daysAgo: 1)
        perform("complete all tasks created yesterday")
        XCTAssertFalse(today.isCompleted, "today's task must be untouched")
        XCTAssertTrue(y1.isCompleted)
        XCTAssertTrue(y2.isCompleted)
    }

    // name-before-verb — "call plumber is done"
    func test_nameBeforeVerb_completesNamedTask() {
        let plumber = seed("Call plumber", daysAgo: 0)
        seed("Water plants", daysAgo: 1)
        perform("call plumber is done")
        XCTAssertTrue(plumber.isCompleted)
    }
}
