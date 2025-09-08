import Foundation

struct TranscriptionCacheKey: Hashable {
    let fileSize: UInt64
    let fileMod: TimeInterval
    let provider: String
    let model: String
    let language: String?
    let preprocessing: Bool
}

final class TranscriptionCache {
    static let shared = TranscriptionCache()
    private let cache = LRUCache<TranscriptionCacheKey, String>(capacity: 50, ttl: 300)

    private init() {}

    func key(for fileURL: URL, provider: String, model: String, language: String?, preprocessing: Bool) -> TranscriptionCacheKey? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber,
              let mod = attrs[.modificationDate] as? Date else { return nil }
        return TranscriptionCacheKey(
            fileSize: size.uint64Value,
            fileMod: mod.timeIntervalSince1970,
            provider: provider,
            model: model,
            language: language,
            preprocessing: preprocessing
        )
    }

    func lookup(_ key: TranscriptionCacheKey) -> String? {
        return cache.get(key)
    }

    func store(_ key: TranscriptionCacheKey, result: String) {
        cache.set(key, result)
    }
}


