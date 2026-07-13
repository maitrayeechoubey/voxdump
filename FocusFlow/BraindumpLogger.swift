import OSLog

// Unified logging for Braindump.
// Messages appear in Console.app (filter: subsystem = "com.braindump")
// AND in Xcode's debug console via the print() companion below.
// Usage: BDLog.speech.log("…") or BDLog.print("…", category: "speech")

enum BDLog {
    static let speech   = Logger(subsystem: "com.braindump", category: "speech")
    static let parsing  = Logger(subsystem: "com.braindump", category: "parsing")
    static let command  = Logger(subsystem: "com.braindump", category: "command")
    static let reminder = Logger(subsystem: "com.braindump", category: "reminder")
    static let nav      = Logger(subsystem: "com.braindump", category: "navigation")

    // Mirror a message to both OSLog and Xcode console.
    static func print(_ message: String, category: String) {
        Swift.print("[braindump:\(category)] \(message)")
    }
}
