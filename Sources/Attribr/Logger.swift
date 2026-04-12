import Foundation
import os.log

/// Internal logger. Only emits when debug mode is on.
/// Uses unified logging (os.log) — visible in Console.app.
final class AttribrLogger: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.mrvltechnologies.attribr", category: "SDK")
    private let isEnabled: Bool

    init(enabled: Bool) {
        self.isEnabled = enabled
    }

    func debug(_ message: String) {
        guard isEnabled else { return }
        logger.debug("🔵 \(message, privacy: .public)")
    }

    func info(_ message: String) {
        guard isEnabled else { return }
        logger.info("ℹ️ \(message, privacy: .public)")
    }

    func error(_ message: String) {
        // Errors always log regardless of debug mode
        logger.error("🔴 \(message, privacy: .public)")
    }
}
