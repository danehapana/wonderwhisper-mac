import Foundation

struct PromptBuilder {
    // Mirrors Android TextProcessingUtils.buildStructuredSystemMessage
    static func buildSystemMessage(base: String, customVocabulary: String, customSpelling: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        out += "<SYSTEM_PROMPT>\n"
        out += trimmedBase
        out += "\n</SYSTEM_PROMPT>\n\n"

        out += "<CONTEXT_USAGE_INSTRUCTIONS>\n"
        out += "Your task is to work ONLY with the content within the '<TRANSCRIPT>' tags.\n\n"
        out += "IMPORTANT: The following context information is ONLY for reference:\n"
        out += "- '<ACTIVE_APPLICATION>': The application currently in focus\n"
        out += "- '<SCREEN_CONTENTS>': Text extracted from the active window\n"
        out += "- '<SELECTED_TEXT>': Text that was selected when recording started\n"
        out += "- '<VOCABULARY>': Important words that should be recognized correctly\n\n"
        out += "Use this context to:\n"
        out += "- Fix transcription errors by referencing names, terms, or content from the context\n"
        out += "- Understand the user's intent and environment\n"
        out += "- Prioritize spelling and forms from context over potentially incorrect transcription\n\n"
        out += "The <TRANSCRIPT> content is your primary focus - enhance it using context as reference only.\n"
        out += "</CONTEXT_USAGE_INSTRUCTIONS>\n\n"

        // <VOCABULARY> contains items from customVocabulary only (no device-level replacements here)
        var vocabItems: [String] = []
        let trimmedVocab = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVocab.isEmpty {
            let separators: Set<Character> = [",", "\n", "\r"]
            let parts = trimmedVocab.split(whereSeparator: { separators.contains($0) })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            vocabItems.append(contentsOf: parts)
        }
        // Note: customSpelling (text replacements) are NOT included in the prompt.
        out += "<VOCABULARY>\n"
        if !vocabItems.isEmpty {
            out += vocabItems.joined(separator: ", ")
        }
        out += "\n</VOCABULARY>\n\n"

        out += "**Output Format:**\n"
        out += "Place your entire, final output inside `<FORMATTED_TEXT>` tags and nothing else.\n\n"
        out += "**Example:**\n"
        out += "Output: <FORMATTED_TEXT>We need $3,000 to analyse the data.</FORMATTED_TEXT>"
        return out
    }

    // Mirrors Android TextProcessingUtils.buildStructuredUserMessage
    static func buildUserMessage(transcription: String,
                                 selectedText: String?,
                                 appName: String?,
                                 screenContents: String?) -> String {
        var out = ""
        out += "<TRANSCRIPT>\n"
        out += transcription
        out += "\n</TRANSCRIPT>\n\n"

        out += "<ACTIVE_APPLICATION>\n"
        out += (appName?.isEmpty == false) ? (appName ?? "Unknown") : "Unknown"
        out += "\n</ACTIVE_APPLICATION>\n\n"

        out += "<SCREEN_CONTENTS>\n"
        out += (screenContents ?? "")
        out += "\n</SCREEN_CONTENTS>\n\n"

        out += "<SELECTED_TEXT>\n"
        out += (selectedText ?? "")
        out += "\n</SELECTED_TEXT>\n\n"
        return out
    }

    // Render a user-configurable system prompt template by injecting current vocabulary and spelling.
    // Supports either a block form (<TAG>...</TAG>) where inner content is replaced, or a self-closing form (<TAG/>)
    // which is expanded to a full block with injected content.
    static func renderSystemPrompt(template: String, customVocabulary: String) -> String {
        var out = template

        // Build vocabulary string (comma-separated, trimmed)
        let trimmedVocab = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        var vocabItems: [String] = []
        if !trimmedVocab.isEmpty {
            let separators: Set<Character> = [",", "\n", "\r"]
            vocabItems = trimmedVocab.split(whereSeparator: { separators.contains($0) })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let vocabJoined = vocabItems.joined(separator: ", ")

        func replaceBlock(tag: String, with content: String) {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            let selfClose = "<\(tag)/>"
            if let range = out.range(of: selfClose) {
                out.replaceSubrange(range, with: "<\(tag)>\n\(content)\n</\(tag)>")
                return
            }
            if let openRange = out.range(of: open), let closeRange = out.range(of: close), openRange.upperBound <= closeRange.lowerBound {
                out.replaceSubrange(openRange.upperBound..<closeRange.lowerBound, with: "\n\(content)\n")
            }
        }

        // Replace vocabulary placeholders
        replaceBlock(tag: "VOCABULARY", with: vocabJoined)

        return out
    }
}
