import Foundation

struct AppConfig {
    // Groq uses OpenAI-compatible endpoints under /openai/v1
    static let groqBase = URL(string: "https://api.groq.com/openai/v1")!
    static let groqAudioTranscriptions = groqBase.appendingPathComponent("audio/transcriptions")
    static let groqChatCompletions = groqBase.appendingPathComponent("chat/completions")

    // Default model IDs (replace with the exact IDs you use in production)
    // NOTE: Confirm the exact Groq model IDs you intend to use.
    static let defaultTranscriptionModel = "whisper-large-v3-turbo"    // Groq Whisper v3 Turbo
    static let defaultLLMModel = "moonshotai/kimi-k2-instruct"          // Kimi K2 Instruct (per Android config)

    // Keychain alias for the Groq API key
    static let groqAPIKeyAlias = "GROQ_API_KEY"

    // A baseline formatting/system prompt; replace with your Android prompt templates
    static let defaultSystemPrompt = "You are a helpful assistant that reformats transcripts according to WonderWhisper rules."
}

