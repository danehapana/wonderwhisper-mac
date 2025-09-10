import Foundation
import OSLog
import os.signpost

final class GroqTranscriptionProvider: TranscriptionProvider {
    private let spLog = OSLog(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "GroqFile-SP")
    private let client: GroqHTTPClient

    init(client: GroqHTTPClient) {
        self.client = client
    }

    struct Response: Decodable {
        let text: String?
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        // For Groq file uploads, avoid preprocessing if the source is already a compressed format
        // (preprocessing expands to large WAV and hurts upload latency). Allow opt-in override.
        let ext = fileURL.pathExtension.lowercased()
        let isCompressed = ["mp3","m4a","aac","ogg","opus","flac"].contains(ext)
        let allowPreprocCompressed = UserDefaults.standard.bool(forKey: "groq.file.preprocessCompressed")
        let applyPreprocessing = AudioPreprocessor.isEnabled && (!isCompressed || allowPreprocCompressed)
        let inputURL = applyPreprocessing ? AudioPreprocessor.processIfEnabled(fileURL) : fileURL

        // Cache lookup keyed by whether preprocessing actually applied
        if let key = TranscriptionCache.shared.key(for: inputURL, provider: "groq", model: settings.model, language: nil, preprocessing: applyPreprocessing),
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
            cacheKey: TranscriptionCache.shared.key(for: inputURL, provider: "groq", model: settings.model, language: nil, preprocessing: applyPreprocessing)
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
        // Optional: tighten decoding by providing language if known (prefer explicit override)
        if let forced = UserDefaults.standard.string(forKey: "transcription.language"), !forced.isEmpty {
            fields["language"] = forced
        } else if let lang = Locale.preferredLanguages.first?.split(separator: "-").first {
            fields["language"] = String(lang)
        }
        fields["temperature"] = "0"
        
        // Signpost around upload+response to measure wall-clock
        let signpostID = OSSignpostID(log: spLog)
        os_signpost(.begin, log: spLog, name: "GroqFileUpload", signpostID: signpostID, "filename=%{public}s model=%{public}s bytes=%{public}lu", filename, settings.model, UInt(data.count))
        let t0 = Date()
        let responseData = try await client.postMultipart(
            to: settings.endpoint,
            fields: fields,
            files: [file],
            timeout: settings.timeout,
            context: settings.context
        )
        let dt = Date().timeIntervalSince(t0)
        os_signpost(.end, log: spLog, name: "GroqFileUpload", signpostID: signpostID, "elapsed=%.3f", dt)
        
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
