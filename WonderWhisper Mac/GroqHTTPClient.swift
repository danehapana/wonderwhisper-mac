import Foundation
import OSLog

struct GroqHTTPClient {
    let apiKeyProvider: () -> String?

    private func authHeader() throws -> String {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw ProviderError.missingAPIKey }
        return "Bearer \(key)"
    }

    func postJSON(to url: URL, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        let start = Date()
        AppLog.network.log("POST JSON to \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try authHeader(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            AppLog.network.error("HTTP \(http.statusCode) for \(url.absoluteString, privacy: .public) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
            throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>")
        }
        AppLog.network.log("OK \(((response as? HTTPURLResponse)?.statusCode ?? -1)) for \(url.lastPathComponent, privacy: .public) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
        return data
    }

    struct MultipartFile {
        let fieldName: String
        let filename: String
        let mimeType: String
        let data: Data
    }

    func postMultipart(to url: URL, fields: [String: String], files: [MultipartFile], timeout: TimeInterval) async throws -> Data {
        let start = Date()
        AppLog.network.log("POST Multipart to \(url.absoluteString, privacy: .public) with \(files.count) file(s)")
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
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            AppLog.network.error("HTTP \(http.statusCode) for \(url.absoluteString, privacy: .public) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
            throw ProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "<no body>")
        }
        AppLog.network.log("OK \(((response as? HTTPURLResponse)?.statusCode ?? -1)) for \(url.lastPathComponent, privacy: .public) in \(Date().timeIntervalSince(start), format: .fixed(precision: 3))s")
        return data
    }
}

