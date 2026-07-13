import AVFoundation
import SwiftData

final class SpeakManager: NSObject, ObservableObject {
    private let synth = AVSpeechSynthesizer()
    @Published var isSpeaking = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func readTasks(_ tasks: [TaskItem], filter: ParsedDump.VoiceCommand.ReadFilter) {
        let cal = Calendar.current
        let subset: [TaskItem]
        switch filter {
        case .today:
            subset = tasks.filter {
                !$0.isCompleted && (
                    $0.dueDate.map { cal.isDateInToday($0) } ??
                    ($0.relativeTime == "today" || $0.relativeTime == "tonight")
                )
            }
        case .pending:
            subset = tasks.filter { !$0.isCompleted }
        case .all:
            subset = tasks
        }

        guard !subset.isEmpty else {
            speak(filter == .today ? "You have no tasks due today." : "Your task list is empty.")
            return
        }

        let count = subset.count
        let intro = filter == .today
            ? "You have \(count) task\(count == 1 ? "" : "s") due today. "
            : "You have \(count) task\(count == 1 ? "" : "s"). "
        let body = subset.enumerated()
            .map { i, t in "\(i + 1). \(t.title)" }
            .joined(separator: ". ")
        speak(intro + body + ".")
    }

    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let utt = AVSpeechUtterance(string: text)
        utt.rate = 0.50
        utt.pitchMultiplier = 1.05
        utt.voice = AVSpeechSynthesisVoice(language: "en-US")
        isSpeaking = true
        synth.speak(utt)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }
}

extension SpeakManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }
}
