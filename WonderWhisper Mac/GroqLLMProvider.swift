import Foundation

final class GroqLLMProvider: LLMProvider {
    private let client: GroqHTTPClient

    init(client: GroqHTTPClient) {
        self.client = client
    }

    struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let role: String; let content: String }
            let index: Int
            let message: Message
        }
        let choices: [Choice]
    }

    func process(text: String, userPrompt: String, settings: LLMSettings) async throws -> String {
        var typedMessages: [ChatRequest.Message] = []
        if let system = settings.systemPrompt, !system.isEmpty {
            typedMessages.append(.init(role: "system", content: system))
        }
        // The 'text' here is the structured context message (<TRANSCRIPT>... etc.)
        typedMessages.append(.init(role: "user", content: text))
        // Optional user addendum
        if !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            typedMessages.append(.init(role: "user", content: userPrompt))
        }

        let req = ChatRequest(model: settings.model, messages: typedMessages, temperature: 0.2)
        let data = try await client.postJSONEncodable(to: settings.endpoint, body: req, timeout: settings.timeout)
        // Parse OpenAI-compatible chat response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return Self.extractFormattedText(from: content)
        }
        // Fallback strict decode
        if let decoded = try? Self.sharedDecoder.decode(ChatResponse.self, from: data),
           let content = decoded.choices.first?.message.content {
            return Self.extractFormattedText(from: content)
        }
        throw ProviderError.decodingFailed
    }

    private static let sharedDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private static func extractFormattedText(from response: String) -> String {
        // Case-insensitive extraction of content between <FORMATTED_TEXT> tags
        let lower = response.lowercased()
        if let openRange = lower.range(of: "<formatted_text>"),
           let closeRange = lower.range(of: "</formatted_text>") {
            let start = response.index(response.startIndex, offsetBy: response.distance(from: lower.startIndex, to: openRange.upperBound))
            let end = response.index(response.startIndex, offsetBy: response.distance(from: lower.startIndex, to: closeRange.lowerBound))
            let inner = response[start..<end]
            return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return response
    }
}
