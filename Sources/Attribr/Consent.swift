import Foundation

/// GDPR consent state. The SDK fires **no network requests** until consent is `.granted`.
public enum ConsentState: String, Sendable, Codable {
    /// Default: consent has not been asked yet. No data is collected.
    case unknown  = "unknown"
    /// User has granted consent. SDK is fully active.
    case granted  = "granted"
    /// User has revoked consent. SDK stops all collection.
    case revoked  = "revoked"
}

/// Thread-safe consent manager. Persists state across sessions via UserDefaults.
final class ConsentManager: @unchecked Sendable {
    private let userDefaultsKey = "com.mrvltechnologies.attribr.consent"
    private let lock = NSLock()
    private var _state: ConsentState

    var state: ConsentState {
        lock.withLock { _state }
    }

    var isGranted: Bool {
        state == .granted
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "com.mrvltechnologies.attribr.consent") ?? ""
        _state = ConsentState(rawValue: raw) ?? .unknown
    }

    func set(_ newState: ConsentState) {
        lock.withLock {
            _state = newState
            UserDefaults.standard.set(newState.rawValue, forKey: userDefaultsKey)
        }
    }
}
