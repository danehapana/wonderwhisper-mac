import Foundation
import OSLog

struct GroqHTTPClient {
    let apiKeyProvider: () -> String?

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false // fail fast; our retry/backoff handles transient offline
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
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

    // Typed JSON encoder variant to avoid bridging to Foundation types
    func postJSONEncodable<T: Encodable>(to url: URL, body: T, timeout: TimeInterval, context: String? = nil) async throws -> Data {
        let start = Date()
        let reqId = UUID().uuidString
        AppLog.network.log("POST JSON [\(context ?? "-")] to \(url.absoluteString, privacy: .public) req=\(reqId)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(context ?? "-", forHTTPHeaderField: "X-WW-Context")
        request.setValue(reqId, forHTTPHeaderField: "X-WW-Request-ID")
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

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
        // Pre-reserve capacity to minimize reallocations during multipart assembly
        let filesBytes = files.reduce(0) { $0 + $1.data.count }
        let estimatedOverhead = (fields.count * 128) + (files.count * 512) + 1024
        body.reserveCapacity(filesBytes + estimatedOverhead)

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

        // If forcing HTTP/2 for uploads, use a curl-based multipart path to avoid HTTP/3/QUIC.
        if AppConfig.forceHTTP2ForUploads {
            AppLog.network.log("Using curl HTTP/2 path for multipart upload req=\(reqId)")
            do {
                return try await postMultipartViaCurl(
                    url: url,
                    fields: fields,
                    files: files,
                    timeout: timeout,
                    context: context,
                    reqId: reqId
                )
            } catch {
                AppLog.network.error("HTTP/2 curl path failed; falling back to URLSession req=\(reqId) error=\((error as NSError).localizedDescription)")
                // Continue to URLSession path below
            }
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(context ?? "-", forHTTPHeaderField: "X-WW-Context")
        request.setValue(reqId, forHTTPHeaderField: "X-WW-Request-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.networkServiceType = .responsiveData
        request.httpBody = body

        // Fast first attempt via URLSession; on timeout/connection errors, fall back to curl HTTP/2 path for robustness
        do {
            let (data, response) = try await dataWithAttemptTimeout(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                AppLog.network.error("HTTP \(http.statusCode) for \(url.absoluteString, privacy: .public) first-attempt in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
                throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>")
            }
            AppLog.network.log("OK \(((response as? HTTPURLResponse)?.statusCode ?? -1)) for \(url.lastPathComponent, privacy: .public) first-attempt in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
            return data
        } catch {
            let ns = error as NSError
            AppLog.network.error("Multipart first-attempt failed (\(ns.domain)#\(ns.code)) req=\(reqId) ctx=\(context ?? "-") — falling back to curl HTTP/2")
            return try await postMultipartViaCurl(
                url: url,
                fields: fields,
                files: files,
                timeout: timeout,
                context: context,
                reqId: reqId
            )
        }
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
            let (data, response) = try await dataWithAttemptTimeout(for: request)
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
            // Retry only on timeout and a couple transient network errors; also retry 429 via header parsing earlier
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

// Enforce per-attempt wall-clock timeout regardless of CFNetwork internals.
private func dataWithAttemptTimeout(for request: URLRequest) async throws -> (Data, URLResponse) {
    let timeout = max(1.0, request.timeoutInterval)
    return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
        // Network task
        group.addTask {
            return try await GroqHTTPClient.session.data(for: request)
        }
        // Timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "Attempt timed out after \(Int(timeout))s"])
        }
        // Return first to finish; cancel the other
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSLocalizedDescriptionKey: "No result"])
        }
        return result
    }
}

// MARK: - Curl-based HTTP/2 multipart uploader (opt-in)
extension GroqHTTPClient {
    private func postMultipartViaCurl(url: URL, fields: [String: String], files: [MultipartFile], timeout: TimeInterval, context: String?, reqId: String, maxAttempts: Int = 3) async throws -> Data {
        let start = Date()
        let apiKey = try authHeader().replacingOccurrences(of: "Bearer ", with: "")
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            do {
                let (data, status) = try runCurlHTTP2Multipart(
                    url: url,
                    apiKey: apiKey,
                    fields: fields,
                    files: files,
                    timeout: timeout,
                    context: context,
                    reqId: reqId
                )
                if !(200...299).contains(status) {
                    AppLog.network.error("HTTP \(status) for \(url.absoluteString, privacy: .public) attempt=\(attempt) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
                    throw ProviderError.http(status: status, body: String(data: data, encoding: .utf8) ?? "<no body>")
                }
                AppLog.network.log("OK \(status) for \(url.lastPathComponent, privacy: .public) attempt=\(attempt) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
                return data
            } catch {
                lastError = error
                let nsErr = error as NSError
                AppLog.network.error("Attempt \(attempt) failed (curl h2) req=\(reqId) ctx=\(context ?? "-") error=\(nsErr.localizedDescription)")
                if attempt >= maxAttempts { break }
                // Exponential backoff with jitter (mirror performWithRetry)
                let base: Double = 0.6
                let backoff = pow(2.0, Double(attempt - 1)) * base
                let jitter = Double.random(in: 0...(base * 0.5))
                let delay = backoff + jitter
                AppLog.network.log("Retrying in \(String(format: "%.2f", delay))s (attempt \(attempt+1)/\(maxAttempts))")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? ProviderError.notImplemented
    }

    private func runCurlHTTP2Multipart(url: URL, apiKey: String, fields: [String: String], files: [MultipartFile], timeout: TimeInterval, context: String?, reqId: String) throws -> (Data, Int) {
        // Create temp files for any in-memory file data
        var tempURLs: [URL] = []
        defer {
            // Best-effort cleanup
            for u in tempURLs { try? FileManager.default.removeItem(at: u) }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")

        var args: [String] = []
        args.append(contentsOf: ["--http2", "--silent", "--show-error"]) // force HTTP/2, quiet output with errors
        // Timeouts: connect-timeout for handshake; max-time for total transfer
        args.append(contentsOf: ["--connect-timeout", "30"]) // conservative connect timeout
        args.append(contentsOf: ["--max-time", String(Int(ceil(timeout)))])
        // Headers
        args.append(contentsOf: ["-H", "Authorization: Bearer \(apiKey)"])
        args.append(contentsOf: ["-H", "X-WW-Context: \(context ?? "-")"])
        args.append(contentsOf: ["-H", "X-WW-Request-ID: \(reqId)"])
        // Fields
        for (k, v) in fields { args.append(contentsOf: ["-F", "\(k)=\(v)"]) }
        // Files
        for f in files {
            // Write data to a temp file so curl can upload from disk
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ww-\(UUID().uuidString)-\(f.filename)")
            try f.data.write(to: tmp)
            tempURLs.append(tmp)
            let form = "\(f.fieldName)=@\(tmp.path);type=\(f.mimeType)"
            args.append(contentsOf: ["-F", form])
        }
        // Instruct curl to print a trailer line with the HTTP status code so we can parse it
        args.append(contentsOf: ["-w", "\n%{http_code}\n"]) // status on its own line
        args.append(url.absoluteString)

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        try proc.run()
        proc.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        if proc.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? "curl failed with status \(proc.terminationStatus)"
            throw ProviderError.http(status: Int(proc.terminationStatus), body: msg)
        }

        // Parse response: body followed by a line with the status code
        guard var out = String(data: outData, encoding: .utf8) else {
            throw ProviderError.decodingFailed
        }
        out = out.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.popLast(), let status = Int(statusLine.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            // If we can't parse status, return body and assume 200 (unlikely but safe fallback)
            return (outData, 200)
        }
        let bodyString = lines.joined(separator: "\n")
        let bodyData = bodyString.data(using: .utf8) ?? Data()
        return (bodyData, status)
    }
}
