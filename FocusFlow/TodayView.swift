import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]

    private var pending: [TaskItem]   { allTasks.filter { !$0.isCompleted } }
    private var completed: [TaskItem] { allTasks.filter { $0.isCompleted } }

    var body: some View {
        NavigationStack {
            List {
                if allTasks.isEmpty {
                    EmptyDumpState()
                        .padding(.top, 100)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(pending) { task in
                        NavigationLink(value: task.persistentModelID) {
                            TaskRowView(task: task)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                task.isCompleted = true
                                task.microSteps.forEach { $0.isCompleted = true }
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            } label: {
                                Label("Done", systemImage: "checkmark.circle.fill")
                            }
                            .tint(.green)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                modelContext.delete(task)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }

                    if !completed.isEmpty {
                        Section {
                            ForEach(completed) { task in
                                NavigationLink(value: task.persistentModelID) {
                                    TaskRowView(task: task).opacity(0.55)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
                                    Button(role: .destructive) {
                                        modelContext.delete(task)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        } header: {
                            Text("COMPLETED")
                                .font(.caption2).fontWeight(.semibold).foregroundStyle(.tertiary)
                                .padding(.top, 12)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.06, green: 0.06, blue: 0.08))
            .navigationTitle("Today")
            .toolbarBackground(Color(red: 0.06, green: 0.06, blue: 0.08), for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !pending.isEmpty {
                        Text("\(pending.count) left")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationDestination(for: PersistentIdentifier.self) { id in
                TaskFocusView(taskID: id)
            }
        }
    }
}

private struct EmptyDumpState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 54))
                .foregroundStyle(.indigo.opacity(0.6))
            Text("Head empty, ready to capture")
                .font(.title3).fontWeight(.semibold).foregroundStyle(.white)
            Text("Tap the mic button for a brain dump")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}
