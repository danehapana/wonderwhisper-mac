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
        let mime = mimeType(for: inputURL.pathExtension.lowercased())
        
        return try await transcribeData(
            data: fileData,
            filename: inputURL.lastPathComponent,
            mimeType: mime,
            settings: settings,
            cacheKey: TranscriptionCache.shared.key(for: inputURL, provider: "groq", model: settings.model, language: nil, preprocessing: preprocessingEnabled)
        )
    }
    
    // New primary transcription method that works with Data objects
    func transcribeData(data: Data, filename: String, mimeType: String, settings: TranscriptionSettings, cacheKey: TranscriptionCacheKey? = nil) async throws -> String {
        // Pre-warm connection during upload preparation for faster subsequent requests
        GroqHTTPClient.preWarmConnection(to: settings.endpoint)
        
        let file = GroqHTTPClient.MultipartFile(
            fieldName: "file",
            filename: filename,
            mimeType: mimeType,
            data: data
        )
        var fields: [String: String] = ["model": settings.model]
        // Optional: tighten decoding by providing language if known
        if let lang = Locale.preferredLanguages.first?.split(separator: "-").first { fields["language"] = String(lang) }
        fields["temperature"] = "0"
        
        let responseData = try await client.postMultipart(
            to: settings.endpoint,
            fields: fields,
            files: [file],
            timeout: settings.timeout,
            context: settings.context
        )
        
        // Many OpenAI-compatible transcription endpoints return {"text": "..."}
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let text = json["text"] as? String {
            if let key = cacheKey {
                TranscriptionCache.shared.store(key, result: text)
            }
            return text
        }
        
        // Try strict decoding fallback with a shared decoder
        if let decoded = try? Self.sharedDecoder.decode(Response.self, from: responseData), let t = decoded.text {
            if let key = cacheKey {
                TranscriptionCache.shared.store(key, result: t)
            }
            return t
        }
        
        throw ProviderError.decodingFailed
    }
    
    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4" // m4a container
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "caf": return "audio/x-caf"
        default: return "application/octet-stream"
        }
    }

    private static let sharedDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
