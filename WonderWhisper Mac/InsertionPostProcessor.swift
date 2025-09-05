import Foundation

enum InsertionPostProcessor {
    // Applies conservative, local formatting tweaks based on surrounding text.
    // - Capitalize first letter if likely at a sentence start
    // - Optionally add a trailing period if the next word starts uppercase
    // Avoids aggressive lowercasing to preserve proper nouns/acronyms.
    static func applySmartFormatting(output: String, before: String, after: String) -> String {
        let trimmedBefore = before
        let trimmedAfter = after

        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return text }

        // Determine if we're at a sentence start: start of field, newline, or explicit sentence-ending punctuation
        let sentenceEnders = CharacterSet(charactersIn: ".!?\n")
        let beforeEndsWithSentenceBreak: Bool = {
            guard let last = trimmedBefore.unicodeScalars.last else { return true }
            return sentenceEnders.contains(last)
        }()

        if beforeEndsWithSentenceBreak {
            // Capitalize first alphabetic character if present
            if let first = text.first, String(first).range(of: "[A-Za-z]", options: .regularExpression) != nil {
                let cap = String(first).uppercased()
                text.replaceSubrange(text.startIndex...text.startIndex, with: cap)
            }
        }

        // If there is no punctuation at the end, and the next visible token likely starts a sentence (uppercase), add a period.
        let endsWithPunctuation = text.range(of: "[.!?]$", options: .regularExpression) != nil
        if !endsWithPunctuation {
            let nextToken = nextWordPrefix(from: trimmedAfter)
            if let token = nextToken, let first = token.first, String(first).range(of: "[A-Z]", options: .regularExpression) != nil {
                text.append(".")
            }
        }

        return text
    }

    private static func nextWordPrefix(from s: String) -> String? {
        // Skip whitespace and punctuation, return the next contiguous letters/digits (up to ~20)
        var started = false
        var result = ""
        for ch in s {
            if !started {
                if ch.isLetter || ch.isNumber { started = true; result.append(ch) }
                else { continue }
            } else {
                if ch.isLetter || ch.isNumber { result.append(ch); if result.count > 20 { break } }
                else { break }
            }
        }
        return result.isEmpty ? nil : result
    }
}

