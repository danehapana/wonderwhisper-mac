import Foundation
import CryptoKit

struct TranscriptionCacheKey: Hashable {
    let fileSize: UInt64
    let fileMod: TimeInterval
    let provider: String
    let model: String
    let language: String?
    let preprocessing: Bool
    let contentHash: String? // Audio content fingerprint for better deduplication
    
    init(fileSize: UInt64, fileMod: TimeInterval, provider: String, model: String, language: String?, preprocessing: Bool, contentHash: String? = nil) {
        self.fileSize = fileSize
        self.fileMod = fileMod
        self.provider = provider
        self.model = model
        self.language = language
        self.preprocessing = preprocessing
        self.contentHash = contentHash
    }
}

final class TranscriptionCache {
    static let shared = TranscriptionCache()
    private let cache = LRUCache<TranscriptionCacheKey, String>(capacity: 100, ttl: 1800) // Extended: 100 entries, 30min TTL

    private init() {}

    func key(for fileURL: URL, provider: String, model: String, language: String?, preprocessing: Bool) -> TranscriptionCacheKey? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber,
              let mod = attrs[.modificationDate] as? Date else { return nil }
        
        // Generate content hash for better deduplication (optional for performance)
        let contentHash = generateContentHash(for: fileURL)
        
        return TranscriptionCacheKey(
            fileSize: size.uint64Value,
            fileMod: mod.timeIntervalSince1970,
            provider: provider,
            model: model,
            language: language,
            preprocessing: preprocessing,
            contentHash: contentHash
        )
    }
    
    // Create cache key from raw audio data
    func key(for audioData: Data, filename: String, provider: String, model: String, language: String?, preprocessing: Bool) -> TranscriptionCacheKey {
        let contentHash = generateContentHash(for: audioData)
        
        return TranscriptionCacheKey(
            fileSize: UInt64(audioData.count),
            fileMod: Date().timeIntervalSince1970, // Current time for in-memory data
            provider: provider,
            model: model,
            language: language,
            preprocessing: preprocessing,
            contentHash: contentHash
        )
    }
    
    // Fast content fingerprinting using first and last audio samples
    private func generateContentHash(for fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        return generateContentHash(for: data)
    }
    
    private func generateContentHash(for data: Data) -> String {
        // For performance, hash only start + middle + end samples (~1KB total)
        let sampleSize = min(256, data.count / 3)
        var hashData = Data()
        
        // Beginning samples
        if data.count > sampleSize {
            hashData.append(data.prefix(sampleSize))
        }
        
        // Middle samples
        if data.count > sampleSize * 2 {
            let midPoint = data.count / 2
            let midStart = max(0, midPoint - sampleSize / 2)
            let midEnd = min(data.count, midPoint + sampleSize / 2)
            hashData.append(data[midStart..<midEnd])
        }
        
        // End samples  
        if data.count > sampleSize {
            hashData.append(data.suffix(sampleSize))
        } else {
            hashData.append(data) // Small files: hash entire content
        }
        
        let digest = SHA256.hash(data: hashData)
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description // 16-char hex
    }

    func lookup(_ key: TranscriptionCacheKey) -> String? {
        return cache.get(key)
    }
    
    // Enhanced lookup that can find similar content by hash
    func lookupByContent(contentHash: String, provider: String, model: String) -> String? {
        // This is a simplified implementation - in practice, you'd maintain a separate hash->key mapping
        // For now, we rely on the content hash being part of the key equality
        return nil // Would need additional indexing to implement efficiently
    }

    func store(_ key: TranscriptionCacheKey, result: String) {
        cache.set(key, result)
    }
    
    // Cache performance statistics
    var cacheStatistics: (hitCount: Int, missCount: Int, totalSize: Int) {
        // Basic stats - LRUCache would need to expose these metrics
        return (0, 0, 0) // Placeholder - would need LRUCache enhancement
    }
    
    // Clear expired entries manually (LRU cache handles this automatically)
    func clearExpired() {
        // LRUCache handles TTL automatically, but this could force cleanup
    }
}


