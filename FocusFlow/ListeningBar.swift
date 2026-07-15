import SwiftUI

/// One reusable bottom "listening" bar used on every voice-enabled screen, so the mic UX is
/// consistent everywhere: same position (bottom), same size, a LIVE transcript so the user can
/// see what the app heard, a clearly-placed mute, a tooltip of example commands, and an optional
/// "+" to start a new capture. Binds to the shared SpeechManager (the single mic owner).
///
/// Before this, each screen rolled its own indicator — center on Home, a small pill at the TOP of
/// the Tasks list, tiny text at the bottom of review/edit — with the only mute inconveniently at
/// the top. See docs/MAINTENANCE.md §20.
struct ListeningBar: View {
    @ObservedObject var speech: SpeechManager
    /// Whether the mic is usable here at all (false on the simulator / when unsupported): the bar
    /// then degrades to just the "+" capture button so tasks can still be added by tapping.
    var voiceEnabled: Bool
    /// Whether always-on listening is currently armed on this screen (drives the "live" look).
    var isListening: Bool
    /// Example commands shown as a tooltip when idle.
    var hint: String
    /// Optional mute toggle (true == listening on). When nil, no mute button is shown.
    var handsFree: Binding<Bool>? = nil
    /// Optional "new capture" action, shown as a + button.
    var onNewDump: (() -> Void)? = nil

    private var muted: Bool { handsFree.map { !$0.wrappedValue } ?? false }
    private var hearing: Bool { voiceEnabled && isListening && speech.isRecording }
    private var transcript: String {
        speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var showTranscript: Bool { hearing && !transcript.isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            if voiceEnabled { statusIcon }
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLine)
                    .font(.bdCaption())
                    .foregroundStyle(statusColor)
                Text(detailLine)
                    .font(.bdBody())
                    .foregroundStyle(showTranscript ? .white : Color.bdMuted2)
                    .lineLimit(2)
                    .animation(.easeOut(duration: 0.15), value: detailLine)
            }
            Spacer(minLength: 8)
            if voiceEnabled, let handsFree { muteButton(handsFree) }
            if let onNewDump { newDumpButton(onNewDump) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.bdCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(hearing ? Color.bdGreen.opacity(0.5) : Color.bdBorder, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Pieces

    private var statusColor: Color {
        if muted { return Color.bdMuted2 }
        if hearing { return Color.bdGreen }
        return voiceEnabled ? Color.bdMuted : Color.bdMuted2
    }

    private var statusLine: String {
        if !voiceEnabled { return "Capture" }
        if muted { return "Muted" }
        return "Listening…"
    }

    private var detailLine: String {
        if !voiceEnabled { return "Tap + to capture a task" }
        if muted { return "Tap Unmute to talk again" }
        if showTranscript { return "\u{201C}\(transcript)\u{201D}" }
        return "Try: \(hint)"
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill((muted ? Color.bdMuted2 : (hearing ? Color.bdGreen : Color.bdPrimary)).opacity(0.16))
                .frame(width: 44, height: 44)
            Image(systemName: muted ? "mic.slash.fill" : (hearing ? "waveform" : "mic.fill"))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(muted ? Color.bdMuted : (hearing ? Color.bdGreen : Color.bdPrimary))
                .symbolEffect(.variableColor.iterative, isActive: hearing)
        }
    }

    private func muteButton(_ handsFree: Binding<Bool>) -> some View {
        Button {
            handsFree.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: handsFree.wrappedValue ? "mic.slash" : "mic")
                    .font(.system(size: 15, weight: .bold))
                Text(handsFree.wrappedValue ? "Mute" : "Unmute").font(.bdMicro())
            }
            .foregroundStyle(handsFree.wrappedValue ? Color.bdMuted : Color.bdPrimary)
            .frame(width: 50, height: 44)
        }
        .accessibilityLabel(handsFree.wrappedValue ? "Mute voice" : "Unmute voice")
    }

    private func newDumpButton(_ action: @escaping () -> Void) -> some View {
        Button {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.bdPrimary))
                .shadow(color: Color.bdPrimary.opacity(0.4), radius: 10, x: 0, y: 4)
        }
        .accessibilityLabel("New task")
    }
}
