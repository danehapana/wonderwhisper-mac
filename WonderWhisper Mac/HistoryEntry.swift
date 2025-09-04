import Foundation

struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var date: Date
    var appName: String?
    var bundleID: String?
    var transcript: String
    var output: String
    // Only store filenames in JSON; resolve to URLs via HistoryStore
    var audioFilename: String?
    // Additional context
    var screenContext: String?
    var selectedText: String?
    // Models
    var transcriptionModel: String?
    var llmModel: String?
    // Performance (seconds)
    var transcriptionSeconds: Double?
    var llmSeconds: Double?
    var totalSeconds: Double?
}
