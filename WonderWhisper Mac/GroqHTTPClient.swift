import Foundation
import OSLog
import Compression
import os.signpost

struct GroqHTTPClient {
    let apiKeyProvider: () -> String?
    static let spLog = OSLog(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Network-SP")

    // Connection pre-warming for faster subsequent requests
    static func preWarmConnection(to url: URL) {
        Task {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 5.0
                // Warm both the default session (used for JSON chat) and the priority session (used in some uploads)
                let req1 = request
                let req2 = request
                async let warm1: (Data, URLResponse) = session.data(for: req1)
                async let warm2: (Data, URLResponse) = prioritySession.data(for: req2)
                _ = try await warm1
                _ = try await warm2
            } catch {
                // Ignore pre-warming errors
            }
        }
    }

    // MARK: - Request Compression
    private static func compressData(_ data: Data) throws -> Data {
        // Simple implementation - for now just return original data
        // Real compression would require more complex implementation
        return data
    }

    private static func shouldCompressRequest(contentLength: Int) -> Bool {
        // Only compress larger payloads where the benefit outweighs the CPU cost
        return contentLength > 2048 // 2KB minimum
    }

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false // fail fast; our retry/backoff handles transient offline
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 8 // Increased for better parallelism
        cfg.timeoutIntervalForRequest = 10 // Reduced from 20s for faster failure detection
        cfg.timeoutIntervalForResource = 30 // Reduced from 60s for tighter timeouts
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true

        // Enable HTTP/3 QUIC support for faster connection establishment
        // Remove Alt-Svc request header; server advertises this in responses
        // cfg.httpAdditionalHeaders = ["Alt-Svc": "h3=\":443\"; ma=86400"]
        cfg.networkServiceType = .responsiveData

        // Connection pooling and keep-alive optimizations
        cfg.httpShouldSetCookies = false
        cfg.connectionProxyDictionary = nil // Direct connections

        return URLSession(configuration: cfg, delegate: GroqURLSessionDelegate.shared, delegateQueue: nil)
    }()

    // Pre-warmed session for critical requests
    static let prioritySession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.httpMaximumConnectionsPerHost = 4 // Dedicated connections
        cfg.timeoutIntervalForRequest = 8 // Very tight for priority requests
        cfg.timeoutIntervalForResource = 25
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.networkServiceType = .responsiveData
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, br", forHTTPHeaderField: "Accept-Encoding")
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(context ?? "-", forHTTPHeaderField: "X-WW-Context")
        request.setValue(reqId, forHTTPHeaderField: "X-WW-Request-ID")
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        return try await performWithRetry(request: request, start: start, context: context)
    }
    // Streaming JSON (SSE) variant for chat completions. Returns the accumulated content string.
    func postJSONEncodableStream<T: Encodable>(to url: URL, body: T, timeout: TimeInterval, context: String? = nil) async throws -> String {
        let start = Date()
        let reqId = UUID().uuidString
        AppLog.network.log("POST JSON STREAM [\(context ?? "-")] to \(url.absoluteString, privacy: .public) req=\(reqId)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Do not set Accept-Encoding for SSE; allow immediate flushes
        request.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue(context ?? "-", forHTTPHeaderField: "X-WW-Context")
        request.setValue(reqId, forHTTPHeaderField: "X-WW-Request-ID")
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)

        // Enforce per-attempt wall-clock timeout for streaming
        return try await withThrowingTaskGroup(of: String.self) { group in
            // Network streaming task
            group.addTask {
                var aggregated = ""
                let (bytes, response) = try await GroqHTTPClient.session.bytes(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    // Read any available body into string for diagnostics
                    var bodySample = ""
                    for try await line in bytes.lines {
                        bodySample += line + "\n"
                        if bodySample.count > 8_192 { break }
                    }
                    throw ProviderError.http(status: http.statusCode, body: bodySample)
                }
                for try await line in bytes.lines {
                    if line.hasPrefix(":") { continue } // comment/keepalive
                    guard line.hasPrefix("data:") else { continue }
                    var payload = String(line.dropFirst(5)) // after "data:"
                    if payload.hasPrefix(" ") { payload.removeFirst() }
                    if payload == "[DONE]" { break }
                    // Parse JSON chunk and extract choices[0].delta.content if present
                    if let data = payload.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let choices = obj["choices"] as? [[String: Any]],
                       let first = choices.first {
                        if let delta = first["delta"] as? [String: Any], let part = delta["content"] as? String {
                            aggregated += part
                        } else if let msg = first["message"] as? [String: Any], let part = msg["content"] as? String {
                            // Some implementations may send full message objects mid-stream
                            aggregated += part
                        }
                    }
                }
                AppLog.network.log("STREAM completed req=\(reqId) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
                return aggregated
            }
            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1.0, timeout) * 1_000_000_000))
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "Stream timed out after \(Int(timeout))s"])
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [NSLocalizedDescriptionKey: "No stream result"])
            }
            return result
        }
    }


    struct MultipartFile {
        let fieldName: String
        let filename: String
        let mimeType: String
        let data: Data

        // Convenience initializer for direct Data upload
        init(fieldName: String, filename: String, mimeType: String, data: Data) {
            self.fieldName = fieldName
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
        }

        // Convenience initializer from file URL (existing behavior)
        init(fieldName: String, filename: String, mimeType: String, fileURL: URL) throws {
            self.fieldName = fieldName
            self.filename = filename
            self.mimeType = mimeType
            self.data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        }
    }

    func postMultipart(to url: URL, fields: [String: String], files: [MultipartFile], timeout: TimeInterval, context: String? = nil) async throws -> Data {
        let start = Date()
        let reqId = UUID().uuidString
        AppLog.network.log("POST Multipart [\(context ?? "-")] to \(url.absoluteString, privacy: .public) with \(files.count) file(s) req=\(reqId)")
        let totalBytes = files.reduce(0) { $0 + $1.data.count }
        os_signpost(.event, log: Self.spLog, name: "WW.net.upload.prepare", "req=%{public}@ bytes=%{public}ld files=%{public}ld", reqId, totalBytes, files.count)
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

        // Optional compression for large payloads
        var finalBody = body
        var shouldCompress = Self.shouldCompressRequest(contentLength: body.count)
        if shouldCompress {
            do {
                let compressedBody = try Self.compressData(body)
                // Only use compression if it actually reduces size significantly
                if compressedBody.count < body.count * 9 / 10 { // 10% reduction minimum
                    finalBody = compressedBody
                    AppLog.network.log("Compressed multipart body: \(body.count) -> \(compressedBody.count) bytes (\(String(format: "%.1f", Double(compressedBody.count)/Double(body.count)*100))%)")
                } else {
                    shouldCompress = false
                }
            } catch {
                AppLog.network.error("Compression failed, using uncompressed body: \(error)")
                shouldCompress = false
            }
        }

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
        request.setValue("gzip, deflate, br, lzfse", forHTTPHeaderField: "Accept-Encoding")
        request.networkServiceType = .responsiveData

        // Set compression headers if body was compressed
        if shouldCompress {
            request.setValue("lzfse", forHTTPHeaderField: "Content-Encoding")
        }

        request.httpBody = finalBody

        // Parallel upload strategy: Try both URLSession and curl HTTP/2 simultaneously, use fastest result
        return try await withThrowingTaskGroup(of: Data.self) { group in
            // Task 1: URLSession with priority session for maximum speed
            group.addTask {
                var priorityRequest = request
                priorityRequest.setValue("max-age=0", forHTTPHeaderField: "Cache-Control")
                priorityRequest.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")

                let (data, response) = try await Self.prioritySession.data(for: priorityRequest)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>")
                }
                return data
            }

            // Task 2: Standard URLSession as fallback
            group.addTask {
                // Add small delay to prefer priority session
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay

                let (data, response) = try await dataWithAttemptTimeout(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>")
                }
                return data
            }

            // Task 3: Curl HTTP/2 as final fallback (with delay)
            if AppConfig.forceHTTP2ForUploads {
                group.addTask {
                    try await Task.sleep(nanoseconds: 200_000_000) // 0.2s delay
                    return try await self.postMultipartViaCurl(
                        url: url,
                        fields: fields,
                        files: files,
                        timeout: timeout,
                        context: context,
                        reqId: reqId
                    )
                }
            }

            // Return the first successful result
            guard let result = try await group.next() else {
                throw ProviderError.notImplemented
            }

            let elapsed = Date().timeIntervalSince(start)
            AppLog.network.log("Parallel upload completed req=\(reqId) in \(elapsed, format: .fixed(precision: 3))s")

            // Cancel remaining tasks
            group.cancelAll()
            return result
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
        let ttfb = (tx.responseStartDate?.timeIntervalSince(tx.requestStartDate ?? tx.fetchStartDate ?? Date()))
        let transfer = (tx.responseEndDate?.timeIntervalSince(tx.responseStartDate ?? tx.responseEndDate ?? Date()))
        AppLog.network.log("Metrics req=\(reqId) ctx=\(ctx) proto=\(proto) dns=\(dns ?? -1)s connect=\(connect ?? -1)s tls=\(tls ?? -1)s ttfb=\(ttfb ?? -1)s transfer=\(transfer ?? -1)s")
    }
}

private func performWithRetry(request: URLRequest, start: Date, context: String?, maxAttempts: Int = 3) async throws -> Data {
    var attempt = 0
    var lastError: Error?
    while attempt < maxAttempts {
        attempt += 1
        let spId = OSSignpostID(log: GroqHTTPClient.spLog)
        os_signpost(.begin, log: GroqHTTPClient.spLog, name: "WW.net.request", signpostID: spId, "attempt=%ld ctx=%{public}@ path=%{public}@", attempt, context ?? "-", request.url?.lastPathComponent ?? "<url>")
        do {
            let (data, response) = try await dataWithAttemptTimeout(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let status = http.statusCode
                if status == 429 {
                    var delay: Double = 1.0
                    if let ra = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(ra) {
                        delay = max(0.1, min(10.0, seconds))
                    }
                    AppLog.network.error("HTTP 429 for \(request.url?.absoluteString ?? "<url>", privacy: .public) attempt=\(attempt) retrying in \(delay, format: .fixed(precision: 2))s")
                    os_signpost(.end, log: GroqHTTPClient.spLog, name: "WW.net.request", signpostID: spId)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    // continue loop (retry)
                    continue
                }
                AppLog.network.error("HTTP \(status) for \(request.url?.absoluteString ?? "<url>", privacy: .public) attempt=\(attempt) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
                throw ProviderError.http(status: status, body: String(data: data, encoding: .utf8) ?? "<no body>")
            }
            AppLog.network.log("OK \(((response as? HTTPURLResponse)?.statusCode ?? -1)) for \(request.url?.lastPathComponent ?? "<url>", privacy: .public) attempt=\(attempt) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
            os_signpost(.end, log: GroqHTTPClient.spLog, name: "WW.net.request", signpostID: spId)
            return data
        } catch {
            lastError = error
            let nsErr = error as NSError
            let code = nsErr.code
            let domain = nsErr.domain
            AppLog.network.error("Attempt \(attempt) failed req=\(request.value(forHTTPHeaderField: "X-WW-Request-ID") ?? "?") ctx=\(context ?? "-") error=\(nsErr.localizedDescription)")
            // Retry only on timeout and a couple transient network errors; also retry 429 via header parsing earlier
            let shouldRetry = (domain == NSURLErrorDomain) && (code == NSURLErrorTimedOut || code == NSURLErrorNetworkConnectionLost || code == NSURLErrorCannotFindHost || code == NSURLErrorCannotConnectToHost)
            os_signpost(.end, log: GroqHTTPClient.spLog, name: "WW.net.request", signpostID: spId)
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
