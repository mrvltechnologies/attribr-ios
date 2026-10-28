import Foundation

/// Result of a network call.
enum NetworkResult: Sendable {
    case success(Data, Int)     // body + status code
    case failure(NetworkError)
}

enum NetworkError: Error, Sendable {
    case noConsent
    case httpError(Int, Data)
    case transportError(Error)
    case encodingError
    case maxRetriesExceeded
}

/// Thin URLSession wrapper for Attribr Edge Function calls.
/// - Passes the API key via `X-Attribr-Key` header.
/// - Exponential back-off on 429 / 5xx: 1s → 2s → 4s (max `maxRetries`).
/// - Fire-and-forget mode: caller does not need to await a response.
final class NetworkClient: @unchecked Sendable {
    private let session: URLSession
    private let apiKey: String
    private let baseURL: URL
    private let maxRetries: Int
    private let logger: AttribrLogger
    /// Consulted immediately before EVERY request attempt (including retries after back-off).
    /// `false` ⇒ nothing is sent and `.failure(.noConsent)` is returned. The GDPR deletion endpoint is
    /// exempted by the caller's gate, never here. Default allows everything (standalone/test use).
    private let consentGate: @Sendable (String) -> Bool

    init(apiKey: String, config: AttribrConfiguration, logger: AttribrLogger, session: URLSession? = nil,
         consentGate: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.consentGate = consentGate
        self.apiKey = apiKey
        self.baseURL = config.baseURL
        self.maxRetries = config.maxRetries
        self.logger = logger

        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = config.requestTimeout
            cfg.timeoutIntervalForResource = config.requestTimeout * 2
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - Public

    func post(path: String, body: Data) async -> NetworkResult {
        await send(method: "POST", path: path, body: body)
    }

    func delete(path: String, body: Data) async -> NetworkResult {
        await send(method: "DELETE", path: path, body: body)
    }

    // MARK: - Private

    private func send(method: String, path: String, body: Data) async -> NetworkResult {
        // Endpoints are normally relative paths resolved against the Supabase
        // Edge Functions `baseURL`. The revenue-discovery intake, however,
        // lives on the Attribr dashboard host as an absolute URL — detect
        // absolute http(s) endpoints and use them as-is so queued
        // `.revenueDiscovery` events flush to the right host. The same
        // `X-Attribr-Key` header applies either way.
        let url: URL
        if path.hasPrefix("https://") || path.hasPrefix("http://"),
           let absolute = URL(string: path) {
            url = absolute
        } else {
            url = baseURL.appendingPathComponent(path)
        }
        var attempt = 0

        while attempt < maxRetries {
            // Dispatch-time consent enforcement: consent may have been withdrawn after this call was
            // scheduled (unstructured Task, queue flush, or a retry sleeping in back-off).
            guard consentGate(path) else {
                logger.debug("\(method) \(path) not sent — consent not granted at dispatch")
                return .failure(.noConsent)
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "X-Attribr-Key")

            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                logger.debug("\(method) \(path) → \(status)")

                if status == 204 || (200...299).contains(status) {
                    return .success(data, status)
                }

                // 429 or 5xx: retry with back-off
                if status == 429 || status >= 500 {
                    attempt += 1
                    if attempt < maxRetries {
                        let delay = pow(2.0, Double(attempt - 1))
                        logger.debug("Retrying in \(delay)s (attempt \(attempt)/\(maxRetries))")
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    return .failure(.maxRetriesExceeded)
                }

                // 4xx (except 429): don't retry
                logger.error("HTTP \(status) from \(path)")
                return .failure(.httpError(status, data))

            } catch {
                attempt += 1
                if attempt < maxRetries {
                    let delay = pow(2.0, Double(attempt - 1))
                    logger.debug("Transport error, retrying in \(delay)s: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                logger.error("Transport error: \(error.localizedDescription)")
                return .failure(.transportError(error))
            }
        }

        return .failure(.maxRetriesExceeded)
    }
}
