import SwiftUI
import SwiftData

struct AllTasksView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @State private var showBrainDump = false

    private var pending: [TaskItem]   { allTasks.filter { !$0.isCompleted } }
    private var completed: [TaskItem] { allTasks.filter { $0.isCompleted } }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.bdBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(alignment: .center) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.bdMuted)
                            .frame(width: 34, height: 34)
                            .background(Color.bdCard)
                            .clipShape(Circle())
                    }
                    Spacer()
                    if !pending.isEmpty {
                        Text("\(pending.count) task\(pending.count == 1 ? "" : "s") left")
                            .font(.bdCaption()).foregroundStyle(Color.bdMuted)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.bdCard).cornerRadius(10)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)

                Text("Tasks")
                    .font(.bdTitle()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 12)

                if allTasks.isEmpty {
                    Spacer()
                    EmptyTasksState()
                    Spacer()
                } else {
                    List {
                        ForEach(pending) { task in
                            NavigationLink(value: AppRoute.taskFocus(task.persistentModelID)) {
                                TaskRowView(task: task)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    task.isCompleted = true
                                    task.microSteps.forEach { $0.isCompleted = true }
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                } label: { Label("Done", systemImage: "checkmark.circle.fill") }
                                .tint(Color.bdGreen)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { modelContext.delete(task) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }

                        if !completed.isEmpty {
                            Section {
                                ForEach(completed) { task in
                                    NavigationLink(value: AppRoute.taskFocus(task.persistentModelID)) {
                                        TaskRowView(task: task).opacity(0.55)
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            task.isCompleted = false
                                            task.microSteps.forEach { $0.isCompleted = false }
                                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        } label: {
                                            Label("Reopen", systemImage: "arrow.uturn.backward.circle.fill")
                                        }
                                        .tint(.orange)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) { modelContext.delete(task) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("COMPLETED")
                                        .font(.bdMicro()).foregroundStyle(Color.bdMuted2)
                                    Spacer()
                                    Button {
                                        completed.forEach { modelContext.delete($0) }
                                    } label: {
                                        Text("Clear all").font(.bdMicro()).foregroundStyle(Color.bdMuted)
                                    }
                                }
                                .padding(.top, 8)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.bdBg)
                }
            }

            // FAB
            Button { showBrainDump = true } label: {
                ZStack {
                    Circle()
                        .fill(Color.bdPrimary)
                        .frame(width: 60, height: 60)
                        .shadow(color: Color.bdPrimary.opacity(0.45), radius: 16, x: 0, y: 6)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.trailing, 24).padding(.bottom, 44)
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $showBrainDump) {
            BrainDumpSheet(onComplete: { showBrainDump = false })
        }
    }
}

private struct EmptyTasksState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 54))
                .foregroundStyle(Color.bdPrimary.opacity(0.5))
            Text("Head empty, ready to capture")
                .font(.bdHeadline()).foregroundStyle(.white)
            Text("Tap the mic button to add tasks")
                .font(.bdBody()).foregroundStyle(Color.bdMuted)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}
