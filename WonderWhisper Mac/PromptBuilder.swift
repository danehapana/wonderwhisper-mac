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

        // <VOCABULARY> contains comma-separated items from customVocabulary,
        // plus both sides of any from=to lines in customSpelling
        var vocabItems: [String] = []
        let trimmedVocab = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVocab.isEmpty {
            let separators: Set<Character> = [",", "\n", "\r"]
            let parts = trimmedVocab.split(whereSeparator: { separators.contains($0) })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            vocabItems.append(contentsOf: parts)
        }
        let trimmedSpelling = customSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSpelling.isEmpty {
            let lines = trimmedSpelling.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            for line in lines where !line.isEmpty && line.contains("=") {
                let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                if parts.count == 2 {
                    let from = parts[0]
                    let to = parts[1]
                    if !from.isEmpty { vocabItems.append(from) }
                    if !to.isEmpty { vocabItems.append(to) }
                }
            }
        }
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
    static func buildUserMessage(transcription: String, selectedText: String?, appName: String?, screenContents: String?) -> String {
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
        out += "\n</SELECTED_TEXT>"
        return out
    }
}
