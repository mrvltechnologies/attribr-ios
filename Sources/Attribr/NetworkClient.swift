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

    init(apiKey: String, config: AttribrConfiguration, logger: AttribrLogger, session: URLSession? = nil) {
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
        let url = baseURL.appendingPathComponent(path)
        var attempt = 0

        while attempt < maxRetries {
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
