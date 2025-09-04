import Foundation

struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let appName: String?
    let bundleID: String?
    let transcript: String
    let output: String
    // Only store filenames in JSON; resolve to URLs via HistoryStore
    let audioFilename: String?
}

