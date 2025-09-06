import Foundation

final class GroqTranscriptionProvider: TranscriptionProvider {
    private let client: GroqHTTPClient

    init(client: GroqHTTPClient) {
        self.client = client
    }

    struct Response: Decodable {
        let text: String?
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        let inputURL = AudioPreprocessor.processIfEnabled(fileURL)
        let fileData = try Data(contentsOf: inputURL)
        let mime: String
        switch inputURL.pathExtension.lowercased() {
        case "wav": mime = "audio/wav"
        case "m4a": mime = "audio/m4a"
        case "aac": mime = "audio/aac"
        case "caf": mime = "audio/x-caf"
        default: mime = "application/octet-stream"
        }
        let file = GroqHTTPClient.MultipartFile(
            fieldName: "file",
            filename: inputURL.lastPathComponent,
            mimeType: mime,
            data: fileData
        )
        var fields: [String: String] = ["model": settings.model]
        // Optional: tighten decoding by providing language if known
        if let lang = Locale.preferredLanguages.first?.split(separator: "-").first { fields["language"] = String(lang) }
        fields["temperature"] = "0"
        let data = try await client.postMultipart(
            to: settings.endpoint,
            fields: fields,
            files: [file],
            timeout: settings.timeout,
            context: settings.context
        )
        // Many OpenAI-compatible transcription endpoints return {"text": "..."}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text
        }
        // Try strict decoding fallback
        if let decoded = try? JSONDecoder().decode(Response.self, from: data), let t = decoded.text {
            return t
        }
        throw ProviderError.decodingFailed
    }
}
