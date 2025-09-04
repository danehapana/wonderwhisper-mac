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
        messages.append(["role": "user", "content": "\(userPrompt)\n\n=== INPUT START ===\n\(text)\n=== INPUT END ==="])        
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
            return content
        }
        // Fallback strict decode
        if let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
           let content = decoded.choices.first?.message.content {
            return content
        }
        throw ProviderError.decodingFailed
    }
}

