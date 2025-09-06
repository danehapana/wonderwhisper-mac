import Foundation
import OSLog

struct GroqHTTPClient {
    let apiKeyProvider: () -> String?

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: cfg, delegate: GroqURLSessionDelegate.shared, delegateQueue: nil)
    }()

    private func authHeader() throws -> String {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw ProviderError.missingAPIKey }
        return "Bearer \(key)"
    }

    func postJSON(to url: URL, body: [String: Any], timeout: TimeInterval, context: String? = nil) async throws -> Data {
        let start = Date()
        let reqId = UUID().uuidString
        AppLog.network.log("POST JSON [\(context ?? "-")] to \(url.absoluteString, privacy: .public) req=\(reqId)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(context ?? "-", forHTTPHeaderField: "X-WW-Context")
        request.setValue(reqId, forHTTPHeaderField: "X-WW-Request-ID")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        return try await performWithRetry(request: request, start: start, context: context)
    }

    struct MultipartFile {
        let fieldName: String
        let filename: String
        let mimeType: String
        let data: Data
    }

    func postMultipart(to url: URL, fields: [String: String], files: [MultipartFile], timeout: TimeInterval, context: String? = nil) async throws -> Data {
        let start = Date()
        let reqId = UUID().uuidString
        AppLog.network.log("POST Multipart [\(context ?? "-")] to \(url.absoluteString, privacy: .public) with \(files.count) file(s) req=\(reqId)")
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func append(_ string: String) { body.append(string.data(using: .utf8)!) }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        for file in files {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.filename)\"\r\n")
            append("Content-Type: \(file.mimeType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }

        append("--\(boundary)--\r\n")

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(context ?? "-", forHTTPHeaderField: "X-WW-Context")
        request.setValue(reqId, forHTTPHeaderField: "X-WW-Request-ID")
        request.httpBody = body

        return try await performWithRetry(request: request, start: start, context: context)
    }
}

// MARK: - URLSession delegate + retry wrapper
final class GroqURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = GroqURLSessionDelegate()

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let tx = metrics.transactionMetrics.last else { return }
        let proto = tx.networkProtocolName ?? "<unknown>"
        let dns = tx.domainLookupEndDate?.timeIntervalSince(tx.domainLookupStartDate ?? tx.fetchStartDate ?? Date())
        let connect = tx.connectEndDate?.timeIntervalSince(tx.connectStartDate ?? tx.domainLookupEndDate ?? tx.fetchStartDate ?? Date())
        let tls = tx.secureConnectionEndDate?.timeIntervalSince(tx.secureConnectionStartDate ?? tx.connectStartDate ?? tx.fetchStartDate ?? Date())
        let req = tx.request
        let reqId = req.value(forHTTPHeaderField: "X-WW-Request-ID") ?? "?"
        let ctx = req.value(forHTTPHeaderField: "X-WW-Context") ?? "-"
        AppLog.network.log("Metrics req=\(reqId) ctx=\(ctx) proto=\(proto) dns=\(dns ?? -1)s connect=\(connect ?? -1)s tls=\(tls ?? -1)s")
    }
}

private func performWithRetry(request: URLRequest, start: Date, context: String?, maxAttempts: Int = 3) async throws -> Data {
    var attempt = 0
    var lastError: Error?
    while attempt < maxAttempts {
        attempt += 1
        do {
            let (data, response) = try await GroqHTTPClient.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                AppLog.network.error("HTTP \(http.statusCode) for \(request.url?.absoluteString ?? "<url>", privacy: .public) attempt=\(attempt) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
                throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>")
            }
            AppLog.network.log("OK \(((response as? HTTPURLResponse)?.statusCode ?? -1)) for \(request.url?.lastPathComponent ?? "<url>", privacy: .public) attempt=\(attempt) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
            return data
        } catch {
            lastError = error
            let nsErr = error as NSError
            let code = nsErr.code
            let domain = nsErr.domain
            AppLog.network.error("Attempt \(attempt) failed req=\(request.value(forHTTPHeaderField: "X-WW-Request-ID") ?? "?") ctx=\(context ?? "-") error=\(nsErr.localizedDescription)")
            // Retry only on timeout and a couple transient network errors
            let shouldRetry = (domain == NSURLErrorDomain) && (code == NSURLErrorTimedOut || code == NSURLErrorNetworkConnectionLost || code == NSURLErrorCannotFindHost || code == NSURLErrorCannotConnectToHost)
            if attempt >= maxAttempts || !shouldRetry { break }
            // Exponential backoff with jitter
            let base: Double = 0.6
            let backoff = pow(2.0, Double(attempt - 1)) * base
            let jitter = Double.random(in: 0...(base * 0.5))
            let delay = backoff + jitter
            AppLog.network.log("Retrying in \(String(format: "%.2f", delay))s (attempt \(attempt+1)/\(maxAttempts))")
            try? await Task.sleep(nanoseconds: UInt64((delay) * 1_000_000_000))
        }
    }
    throw lastError ?? ProviderError.notImplemented
}

