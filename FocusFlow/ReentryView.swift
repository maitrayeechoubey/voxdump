import SwiftUI
import SwiftData

struct ReentryView: View {
    let onContinue: (TaskItem) -> Void
    let onDismiss: () -> Void

    @Query(
        filter: #Predicate<TaskItem> { !$0.isCompleted },
        sort: \TaskItem.createdAt,
        order: .reverse
    ) private var incompleteTasks: [TaskItem]

    // Voice on the "welcome back" screen (owner "reentry"). Home resigns its mic while this cover is
    // up (canListen is false when showReentry), so this is the sole listener.
    @ObservedObject private var speech = SpeechManager.shared
    @State private var handsFree = true
    private var voiceSupported: Bool { VoiceEnv.supported }
    private var voiceActive: Bool { voiceSupported && handsFree }

    private var primaryTask: TaskItem? {
        incompleteTasks.first(where: { $0.isInProgress }) ?? incompleteTasks.first
    }
    private var secondaryTasks: [TaskItem] {
        guard let primary = primaryTask else { return [] }
        return Array(incompleteTasks.filter { $0.id != primary.id }.prefix(2))
    }

    var body: some View {
        ZStack {
            Color.bdBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.bdMuted)
                            .frame(width: 32, height: 32)
                            .background(Color.bdCard)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20).padding(.top, 20)

                Spacer().frame(height: 32)

                VStack(spacing: 6) {
                    Text("Welcome back.")
                        .font(.bdTitle()).foregroundStyle(.white)
                    Text("Where were you?")
                        .font(.bdHeadline()).foregroundStyle(Color.bdMuted)
                }

                Spacer().frame(height: 40)

                if let task = primaryTask {
                    VStack(spacing: 10) {
                        primaryCard(task)
                        ForEach(secondaryTasks) { t in secondaryRow(t) }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    Button { onContinue(task) } label: {
                        Text("Continue")
                            .font(.bdBody()).fontWeight(.semibold).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Color.bdPrimary)
                            .cornerRadius(14)
                            .shadow(color: Color.bdPrimary.opacity(0.35), radius: 12, x: 0, y: 4)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 48)
                } else {
                    Spacer()
                    Text("No tasks in progress.").font(.bdBody()).foregroundStyle(Color.bdMuted)
                    Spacer()
                    Button { onDismiss() } label: {
                        Text("Go Home")
                            .font(.bdBody()).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(Color.bdCard)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 48)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if voiceSupported {
                ListeningBar(
                    speech: speech,
                    voiceEnabled: voiceSupported,
                    isListening: voiceActive,
                    hint: "\u{201C}continue\u{201D}, \u{201C}go home\u{201D}",
                    handsFree: $handsFree
                )
            }
        }
        .onAppear { syncVoice() }
        .onDisappear { speech.stopListening(as: "reentry") }
        .onChange(of: handsFree) { _, _ in syncVoice() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .voxDebugInject)) { note in
            if voiceActive, let text = note.object as? String { evaluate(text) }
        }
        #endif
    }

    // MARK: - Hands-free voice (owner "reentry")

    private func syncVoice() {
        if voiceActive {
            speech.listen(as: "reentry") { text in evaluate(text) }
        } else {
            speech.stopListening(as: "reentry")
        }
    }

    private func evaluate(_ text: String) {
        let t = text.lowercased()
        let words = Set(t.split { !($0.isLetter || $0.isNumber) }.map(String.init))
        func word(_ ws: String...) -> Bool { ws.contains { words.contains($0) } }
        func phrase(_ ps: String...) -> Bool { ps.contains { t.contains($0) } }
        // Dismiss checked first, so "no thanks" / "not now" never reads as continue.
        if word("dismiss", "no", "nope", "close", "cancel", "skip", "later")
            || phrase("go home", "not now", "never mind", "nevermind", "go away") {
            onDismiss(); return
        }
        if let task = primaryTask,
           word("continue", "resume", "yes", "yeah", "yep", "go", "keep", "open", "start")
            || phrase("keep going", "pick up", "pick it up", "let's go", "lets go", "continue task") {
            onContinue(task); return
        }
    }

    private func primaryCard(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CategoryChip(category: task.category)
                Spacer()
                if task.isInProgress {
                    Text("IN PROGRESS")
                        .font(.bdMicro()).foregroundStyle(Color.bdGreen)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.bdGreen.opacity(0.12))
                        .cornerRadius(6)
                }
            }
            Text(task.title)
                .font(.bdHeadline()).foregroundStyle(.white).lineLimit(2)

            if task.microSteps.count > 0 {
                let done = task.completedMicroStepCount
                let total = task.microSteps.count
                HStack(spacing: 5) {
                    ForEach(0..<total, id: \.self) { i in
                        Capsule()
                            .fill(i < done ? Color.bdGreen : Color.bdBorder)
                            .frame(width: i < done ? 16 : 6, height: 6)
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.bdCard))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.bdPrimary.opacity(0.3), lineWidth: 1))
    }

    private func secondaryRow(_ task: TaskItem) -> some View {
        HStack(spacing: 10) {
            CategoryChip(category: task.category)
            Text(task.title)
                .font(.bdCaption()).foregroundStyle(Color.bdMuted).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.bdCard2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.bdBorder, lineWidth: 1))
    }
}
