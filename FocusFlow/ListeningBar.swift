import SwiftUI

/// One reusable bottom "listening" bar used on every voice-enabled screen, so the mic UX is
/// consistent everywhere: same position (bottom), same size, a LIVE transcript so the user can see
/// what the app heard, an always-visible tooltip of example commands, a clearly-placed mute, and an
/// always-tappable record mic (so tapping to talk is available even when muted / when the mic can't
/// stream). Binds to the shared SpeechManager (the single mic owner). See docs/qa-voice-testing.md.
struct ListeningBar: View {
    @ObservedObject var speech: SpeechManager
    /// Whether the mic can stream here (false on the simulator / when unsupported). The bar still
    /// shows the record button so tasks can be captured by tapping.
    var voiceEnabled: Bool
    /// Whether always-on listening is currently armed on this screen (drives the "live" look).
    var isListening: Bool
    /// Example commands, always shown as a tooltip so the user has clues on what to say.
    var hint: String
    /// Optional mute toggle (true == listening on). When nil, no mute button is shown.
    var handsFree: Binding<Bool>? = nil
    /// Optional "tap to record" action (opens capture). Shown as a mic button that ALWAYS works,
    /// including while muted — we never take away the tap experience.
    var onNewDump: (() -> Void)? = nil

    private var muted: Bool { handsFree.map { !$0.wrappedValue } ?? false }
    private var hearing: Bool { voiceEnabled && isListening && speech.isRecording }
    private var transcript: String { speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showTranscript: Bool { hearing && !transcript.isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(topLine)
                    .font(.bdCaption()).foregroundStyle(topColor).lineLimit(1)
                    .animation(.easeOut(duration: 0.15), value: topLine)
                Text("Try: \(hint)")                      // always-visible tooltip
                    .font(.bdMicro()).foregroundStyle(Color.bdMuted2).lineLimit(1)
            }
            Spacer(minLength: 8)
            if voiceEnabled, let handsFree { muteButton(handsFree) }
            if let onNewDump { recordButton(onNewDump) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.bdCard)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(hearing ? Color.bdGreen.opacity(0.5) : Color.bdBorder, lineWidth: 1))
        )
        .padding(.horizontal, 16).padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Pieces

    private var topLine: String {
        if !voiceEnabled { return "Tap the mic to capture" }
        if muted { return "Muted" }
        if showTranscript { return "\u{201C}\(transcript)\u{201D}" }
        return "Listening…"
    }

    private var topColor: Color {
        if showTranscript { return .white }
        if muted { return Color.bdMuted2 }
        return voiceEnabled ? Color.bdGreen : Color.bdMuted
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill((muted ? Color.bdMuted2 : (hearing ? Color.bdGreen : Color.bdPrimary)).opacity(0.16))
                .frame(width: 40, height: 40)
            Image(systemName: muted ? "mic.slash.fill" : (hearing ? "waveform" : "mic.fill"))
                .font(.system(size: 17, weight: .bold))
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

    /// Always present, always tappable — the tap-to-record affordance that survives muting.
    private func recordButton(_ action: @escaping () -> Void) -> some View {
        Button {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.bdPrimary))
                .shadow(color: Color.bdPrimary.opacity(0.4), radius: 10, x: 0, y: 4)
        }
        .accessibilityLabel("Tap to record a new task")
    }
}
