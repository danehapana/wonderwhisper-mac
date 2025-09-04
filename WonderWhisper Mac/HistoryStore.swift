import Foundation
import AppKit

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let baseDir: URL
    private let entriesDir: URL
    private let audioDir: URL

    init() {
        let fm = FileManager.default
        let appSupport = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = appSupport.appendingPathComponent("WonderWhisper", isDirectory: true)
        let base = root.appendingPathComponent("History", isDirectory: true)
        self.baseDir = base
        self.entriesDir = base.appendingPathComponent("entries", isDirectory: true)
        self.audioDir = base.appendingPathComponent("audio", isDirectory: true)
        try? fm.createDirectory(at: self.entriesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: self.audioDir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: entriesDir, includingPropertiesForKeys: nil) else { return }
        var loaded: [HistoryEntry] = []
        let decoder = JSONDecoder()
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let entry = try? decoder.decode(HistoryEntry.self, from: data) {
                loaded.append(entry)
            }
        }
        loaded.sort { $0.date > $1.date }
        self.entries = loaded
    }

    func append(fileURL: URL?, appName: String?, bundleID: String?, transcript: String, output: String, screenContext: String?, selectedText: String?, transcriptionModel: String?, llmModel: String?, transcriptionSeconds: Double?, llmSeconds: Double?, totalSeconds: Double?) async {
        let id = UUID()
        let date = Date()
        var audioFilename: String? = nil

        // Move/copy audio into persistent store
        if let src = fileURL {
            let dest = audioDir.appendingPathComponent("\(id).\(src.pathExtension.isEmpty ? "m4a" : src.pathExtension)")
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.moveItem(at: src, to: dest)
                audioFilename = dest.lastPathComponent
            } catch {
                // If move fails (e.g., permission), try copy
                do {
                    try FileManager.default.copyItem(at: src, to: dest)
                    audioFilename = dest.lastPathComponent
                } catch {
                    audioFilename = nil
                }
            }
        }

        var entry = HistoryEntry(
            id: id,
            date: date,
            appName: appName,
            bundleID: bundleID,
            transcript: transcript,
            output: output,
            audioFilename: audioFilename,
            screenContext: screenContext,
            selectedText: selectedText,
            transcriptionModel: transcriptionModel,
            llmModel: llmModel,
            transcriptionSeconds: transcriptionSeconds,
            llmSeconds: llmSeconds,
            totalSeconds: totalSeconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let path = entriesDir.appendingPathComponent("\(id).json")
        do {
            let data = try encoder.encode(entry)
            try data.write(to: path, options: .atomic)
        } catch {
            // ignore persistence failure for now
        }
        entries.insert(entry, at: 0)
    }

    func replace(id: UUID, with updated: HistoryEntry) async {
        // Persist to disk
        let path = entriesDir.appendingPathComponent("\(id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(updated)
            try data.write(to: path, options: .atomic)
        } catch {
            // ignore
        }
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx] = updated
            // Move to top
            entries.remove(at: idx)
            entries.insert(updated, at: 0)
        }
    }

    func audioURL(for entry: HistoryEntry) -> URL? {
        guard let name = entry.audioFilename else { return nil }
        return audioDir.appendingPathComponent(name)
    }

    func revealInFinder(entry: HistoryEntry) {
        if let url = audioURL(for: entry) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(entriesDir)
        }
    }
}
