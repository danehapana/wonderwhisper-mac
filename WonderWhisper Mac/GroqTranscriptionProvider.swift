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
        // Cache lookup
        let preprocessingEnabled = UserDefaults.standard.bool(forKey: "audio.preprocess.enabled")
        if let key = TranscriptionCache.shared.key(for: inputURL, provider: "groq", model: settings.model, language: nil, preprocessing: preprocessingEnabled),
           let cached = TranscriptionCache.shared.lookup(key) {
            return cached
        }
        // Memory-map audio to reduce peak memory and speed up reads
        let fileData = try Data(contentsOf: inputURL, options: .mappedIfSafe)
        let mime: String
        switch inputURL.pathExtension.lowercased() {
        case "wav": mime = "audio/wav"
        case "m4a": mime = "audio/mp4" // m4a container
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
            if let key = TranscriptionCache.shared.key(for: inputURL, provider: "groq", model: settings.model, language: nil, preprocessing: preprocessingEnabled) {
                TranscriptionCache.shared.store(key, result: text)
            }
            return text
        }
        // Try strict decoding fallback with a shared decoder
        if let decoded = try? Self.sharedDecoder.decode(Response.self, from: data), let t = decoded.text {
            if let key = TranscriptionCache.shared.key(for: inputURL, provider: "groq", model: settings.model, language: nil, preprocessing: preprocessingEnabled) {
                TranscriptionCache.shared.store(key, result: t)
            }
            return t
        }
        throw ProviderError.decodingFailed
    }

    private static let sharedDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
