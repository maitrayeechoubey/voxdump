import XCTest
@testable import FocusFlow

// MARK: - VoxdumpListeningBarTests
// The rule the regression violated: while actively listening, the bar shows MUTE only — a
// "tap to record" mic next to a live mic is confusing. The record mic returns only when muted
// (so you can still tap to capture) or when voice can't stream (simulator / unsupported).

final class VoxdumpListeningBarTests: XCTestCase {

    private func c(voice: Bool, muted: Bool, mute: Bool = true, record: Bool = true) -> ListeningBarControls {
        .resolve(voiceEnabled: voice, muted: muted, hasMuteToggle: mute, hasRecordAction: record)
    }

    // Actively listening (voice on, not muted): mute only, NO record mic. (The reported bug.)
    func test_listening_showsMuteOnly() {
        let r = c(voice: true, muted: false)
        XCTAssertTrue(r.showMute)
        XCTAssertFalse(r.showRecordMic, "no tap-to-record mic while the mic is already open")
    }

    // Muted: the record mic returns so you can still tap to capture; mute (as Unmute) stays.
    func test_muted_showsRecordMicAndMute() {
        let r = c(voice: true, muted: true)
        XCTAssertTrue(r.showMute)
        XCTAssertTrue(r.showRecordMic)
    }

    // Simulator / voice unsupported: no mute (nothing to mute); record mic present to capture.
    func test_voiceUnsupported_showsRecordMicNoMute() {
        let r = c(voice: false, muted: false)
        XCTAssertFalse(r.showMute)
        XCTAssertTrue(r.showRecordMic)
    }

    // Review/edit screens pass no mute toggle and no capture action: bar is status + tooltip only.
    func test_noControls_whenNeitherProvided() {
        let r = c(voice: true, muted: false, mute: false, record: false)
        XCTAssertFalse(r.showMute)
        XCTAssertFalse(r.showRecordMic)
    }
}
