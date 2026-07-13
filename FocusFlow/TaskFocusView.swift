import SwiftUI
import SwiftData

struct TaskFocusView: View {
    @State private var taskID: PersistentIdentifier
    @Environment(\.dismiss) private var dismiss
    @Query private var allTasks: [TaskItem]

    @State private var showToast = false
    @State private var toastText = ""
    // Slide direction for the last prev/next navigation so the content animates the right way.
    @State private var navEdge: Edge = .trailing

    init(taskID: PersistentIdentifier) {
        _taskID = State(initialValue: taskID)
    }

    private var task: TaskItem? { allTasks.first { $0.persistentModelID == taskID } }

    private var incompleteTasks: [TaskItem] {
        allTasks.filter { !$0.isCompleted }.sorted { $0.createdAt < $1.createdAt }
    }
    private var taskIndex: Int? { incompleteTasks.firstIndex { $0.persistentModelID == taskID } }
    private var canGoPrevious: Bool { (taskIndex ?? 0) > 0 }
    private var canGoNext: Bool {
        guard let i = taskIndex else { return false }
        return i + 1 < incompleteTasks.count
    }

    var body: some View {
        ZStack {
            Color.bdBg.ignoresSafeArea()
            if let task {
                mainContent(task)
                    .id(task.persistentModelID)
                    .transition(.asymmetric(
                        insertion: .move(edge: navEdge),
                        removal: .move(edge: navEdge == .trailing ? .leading : .trailing)
                    ))
            } else {
                Color.bdBg.ignoresSafeArea()
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() }
                    }
            }
            if showToast { toastOverlay.zIndex(10) }
        }
        .navigationBarHidden(true)
        // Swipe right -> next task, swipe left -> previous (same "right = forward"
        // convention as the review cards). simultaneousGesture so the step list still
        // scrolls vertically; we only act on clearly-horizontal swipes.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { v in
                    let dx = v.translation.width
                    let dy = v.translation.height
                    guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                    if dx > 0 { goToNext() } else { goToPrevious() }
                }
        )
    }

    @ViewBuilder
    private func mainContent(_ task: TaskItem) -> some View {
        let done = task.completedMicroStepCount
        let total = task.microSteps.count

        VStack(alignment: .leading, spacing: 0) {
            // Nav bar
            HStack {
                Button { dismiss() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Tasks").font(.bdCaption())
                    }
                    .foregroundStyle(Color.bdMuted)
                }
                Spacer()
                if let idx = taskIndex {
                    HStack(spacing: 12) {
                        Button { goToPrevious() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .disabled(!canGoPrevious)
                        .foregroundStyle(canGoPrevious ? Color.bdMuted : Color.bdBorder)

                        Text("TASK \(idx + 1) OF \(incompleteTasks.count)")
                            .font(.bdMicro()).foregroundStyle(Color.bdMuted)

                        Button { goToNext() } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .disabled(!canGoNext)
                        .foregroundStyle(canGoNext ? Color.bdMuted : Color.bdBorder)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)

            Spacer().frame(height: 32)

            // Title section
            VStack(alignment: .leading, spacing: 10) {
                CategoryChip(category: task.category)
                Text(task.title)
                    .font(.bdTitle()).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            Spacer().frame(height: 40)

            // Full checklist: show every micro-step at once so the whole plan is visible.
            // Tap any step to check it off (no more one-at-a-time reveal).
            if total > 0 {
                Text("STEPS")
                    .font(.bdMicro()).foregroundStyle(Color.bdMuted)
                    .padding(.horizontal, 24).padding(.bottom, 10)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(task.microSteps.sorted { $0.order < $1.order }, id: \.persistentModelID) { s in
                            stepRow(step: s, task: task)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                if task.isCompleted {
                    completedBadge(task: task).padding(.horizontal, 24).padding(.vertical, 12)
                } else if task.microSteps.allSatisfy(\.isCompleted) {
                    allStepsDoneCard(task).padding(.horizontal, 24).padding(.vertical, 12)
                }
            } else if task.isCompleted {
                Spacer()
                completedBadge(task: task).padding(.horizontal, 24)
                Spacer()
            } else {
                Spacer()
                allStepsDoneCard(task).padding(.horizontal, 24)
                Spacer()
            }

            Spacer()

            // Dot progress bar
            if total > 0 {
                HStack(spacing: 6) {
                    ForEach(0..<total, id: \.self) { i in
                        Capsule()
                            .fill(i < done ? Color.bdGreen : Color.bdBorder)
                            .frame(width: i < done ? 20 : 8, height: 8)
                            .animation(.spring(response: 0.3), value: done)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 10)
                Text("Tap a step to check it off")
                    .font(.bdMicro()).foregroundStyle(Color.bdMuted2)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 36)
            }
        }
    }

    private func stepRow(step: MicroStep, task: TaskItem) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            step.isCompleted.toggle()
            // Keep the parent task's completion in sync with its steps.
            task.isCompleted = task.microSteps.allSatisfy(\.isCompleted)
            if task.isCompleted { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: step.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(step.isCompleted ? Color.bdGreen : Color.bdMuted)
                Text(step.text)
                    .font(.bdBody())
                    .foregroundStyle(step.isCompleted ? Color.bdMuted : .white)
                    .strikethrough(step.isCompleted, color: Color.bdMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.bdCard))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.bdBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func allStepsDoneCard(_ task: TaskItem) -> some View {
        Button {
            task.isCompleted = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showFeedback("Task complete!")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(Color.bdGreen)
                Text("Mark task complete")
                    .font(.bdBody()).foregroundStyle(Color.bdGreen)
                Spacer()
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.bdGreen.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.bdGreen.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func completedBadge(task: TaskItem) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.bdGreen.opacity(0.12)).frame(width: 64, height: 64)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(Color.bdGreen)
            }
            Text("All done!").font(.bdHeadline()).foregroundStyle(Color.bdGreen)
            Button {
                task.isCompleted = false
                task.microSteps.forEach { $0.isCompleted = false }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Mark incomplete")
                        .font(.bdCaption())
                }
                .foregroundStyle(Color.bdMuted)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.bdCard)
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.bdBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    // Move to the next incomplete task (task N -> N+1). Bounded; a light warning
    // haptic at the end so an edge swipe still feels intentional, not broken.
    private func goToNext() {
        guard let i = taskIndex, i + 1 < incompleteTasks.count else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        navEdge = .trailing
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            taskID = incompleteTasks[i + 1].persistentModelID
        }
    }

    // Move to the previous incomplete task (task N -> N-1).
    private func goToPrevious() {
        guard let i = taskIndex, i > 0 else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        navEdge = .leading
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            taskID = incompleteTasks[i - 1].persistentModelID
        }
    }

    private func showFeedback(_ text: String) {
        toastText = text
        withAnimation(.spring(response: 0.3)) { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) { showToast = false }
        }
    }

    private var toastOverlay: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.bdGreen)
                Text(toastText).font(.bdCaption()).foregroundStyle(.white)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color.bdCard)
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.bdBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.top, 64)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
