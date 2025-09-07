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
        var messages: [[String: Any]] = []
        if let system = settings.systemPrompt, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        // The 'text' here is the structured context message (<TRANSCRIPT>... etc.)
        messages.append(["role": "user", "content": text])
        // If the user provided an additional user prompt, include it as a second user message
        if !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "user", "content": userPrompt])
        }

        let body: [String: Any] = [
            "model": settings.model,
            "messages": messages,
            "temperature": 0.2
        ]
        let data = try await client.postJSON(to: settings.endpoint, body: body, timeout: settings.timeout)
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
