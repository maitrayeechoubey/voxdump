import SwiftUI
import SwiftData

struct TaskFocusView: View {
    let taskID: PersistentIdentifier
    @Environment(\.dismiss) private var dismiss
    @Query private var allTasks: [TaskItem]

    @State private var dragOffset: CGFloat = 0
    @State private var showToast = false
    @State private var toastText = ""

    private var task: TaskItem? { allTasks.first { $0.persistentModelID == taskID } }

    private var incompleteTasks: [TaskItem] {
        allTasks.filter { !$0.isCompleted }.sorted { $0.createdAt < $1.createdAt }
    }
    private var taskIndex: Int? { incompleteTasks.firstIndex { $0.persistentModelID == taskID } }

    var body: some View {
        ZStack {
            Color.bdBg.ignoresSafeArea()
            if let task {
                mainContent(task)
            } else {
                Color.bdBg.ignoresSafeArea()
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dismiss() }
                    }
            }
            if showToast { toastOverlay.zIndex(10) }
        }
        .navigationBarHidden(true)
    }

    @ViewBuilder
    private func mainContent(_ task: TaskItem) -> some View {
        let step = task.firstIncompleteStep
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
                    Text("TASK \(idx + 1) OF \(incompleteTasks.count)")
                        .font(.bdMicro()).foregroundStyle(Color.bdMuted)
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

            if let step {
                // Next step card
                VStack(alignment: .leading, spacing: 10) {
                    Text("NEXT STEP")
                        .font(.bdMicro()).foregroundStyle(Color.bdMuted)
                        .padding(.horizontal, 24)

                    stepCard(step: step)
                        .padding(.horizontal, 24)
                        .offset(x: dragOffset)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    if v.translation.width > 0 { dragOffset = v.translation.width }
                                }
                                .onEnded { v in
                                    if v.translation.width > 90 {
                                        completeStep(step, task: task)
                                    }
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                        dragOffset = 0
                                    }
                                }
                        )
                }
            } else if !task.isCompleted {
                allStepsDoneCard(task).padding(.horizontal, 24)
            } else {
                completedBadge(task: task).padding(.horizontal, 24)
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
                .padding(.horizontal, 24).padding(.bottom, 12)
            }

            if step != nil {
                Text("Swipe right or tap to complete step")
                    .font(.bdMicro()).foregroundStyle(Color.bdMuted2)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 44)
            }
        }
    }

    private func stepCard(step: MicroStep) -> some View {
        let progress = min(1.0, dragOffset / 90.0)
        return Button {
            if let t = task { completeStep(step, task: t) }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.bdPrimary.opacity(0.15 + 0.25 * progress))
                        .frame(width: 40, height: 40)
                    Image(systemName: progress > 0.85 ? "checkmark" : "arrow.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.bdPrimary)
                }
                Text(step.text)
                    .font(.bdBody()).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.bdCard)
                    .shadow(color: Color.bdPrimary.opacity(0.12 * progress), radius: 20, x: 0, y: 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.bdPrimary.opacity(0.2 + 0.4 * progress), lineWidth: 1)
            )
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

    private func completeStep(_ step: MicroStep, task: TaskItem) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        step.isCompleted = true
        showFeedback("Step done!")
        if task.microSteps.allSatisfy(\.isCompleted) {
            task.isCompleted = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
