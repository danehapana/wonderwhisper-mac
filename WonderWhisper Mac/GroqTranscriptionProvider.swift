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
        let fileData = try Data(contentsOf: fileURL)
        let mime: String
        switch fileURL.pathExtension.lowercased() {
        case "wav": mime = "audio/wav"
        case "m4a": mime = "audio/m4a"
        case "aac": mime = "audio/aac"
        case "caf": mime = "audio/x-caf"
        default: mime = "application/octet-stream"
        }
        let file = GroqHTTPClient.MultipartFile(
            fieldName: "file",
            filename: fileURL.lastPathComponent,
            mimeType: mime,
            data: fileData
        )
        let fields = [
            "model": settings.model
        ]
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
