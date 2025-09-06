import Foundation

public enum ProviderError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case http(status: Int, body: String)
    case decodingFailed
    case notImplemented

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "API key not available"
        case .invalidURL: return "Invalid URL"
        case .http(let status, let body): return "HTTP error (\(status)): \(body)"
        case .decodingFailed: return "Response decoding failed"
        case .notImplemented: return "Not implemented"
        }
    }
}

public struct TranscriptionSettings {
    public let endpoint: URL
    public let model: String
    public let timeout: TimeInterval
    // Optional context label to help diagnose where requests originate (e.g., "hotkey", "reprocess")
    public let context: String?
    public init(endpoint: URL, model: String, timeout: TimeInterval = 180, context: String? = nil) {
        self.endpoint = endpoint
        self.model = model
        self.timeout = timeout
        self.context = context
    }
}

public protocol TranscriptionProvider {
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String
}

public struct LLMSettings {
    public let endpoint: URL
    public let model: String
    public let systemPrompt: String?
    public let timeout: TimeInterval
    public init(endpoint: URL, model: String, systemPrompt: String? = nil, timeout: TimeInterval = 60) {
        self.endpoint = endpoint
        self.model = model
        self.systemPrompt = systemPrompt
        self.timeout = timeout
    }
}

public protocol LLMProvider {
    func process(text: String, userPrompt: String, settings: LLMSettings) async throws -> String
}

