import Foundation

struct PromptBuilder {
    static func buildSystemMessage(base: String, customVocabulary: String, customSpelling: String) -> String {
        var sections: [String] = []
        if !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(base)
        }
        if !customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Vocabulary: " + customVocabulary)
        }
        if !customSpelling.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Spelling Rules (from=to per line):\n" + customSpelling)
        }
        return sections.joined(separator: "\n\n")
    }

    static func buildUserMessage(transcription: String, focusedText: String?, appName: String?) -> String {
        var msg = "TRANSCRIPT:\n" + transcription
        var contextLines: [String] = []
        if let appName, !appName.isEmpty {
            contextLines.append("APP_NAME: \(appName)")
        }
        if let focusedText, !focusedText.isEmpty {
            contextLines.append("FOCUSED_TEXT:\n\(focusedText)")
        }
        if !contextLines.isEmpty {
            msg += "\n\nSCREEN_CONTEXT:\n" + contextLines.joined(separator: "\n")
        }
        return msg
    }
}

