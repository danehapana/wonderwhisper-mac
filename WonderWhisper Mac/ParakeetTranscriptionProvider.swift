import Foundation
import AVFoundation

#if canImport(FluidAudio)
import FluidAudio
import OSLog

final class ParakeetTranscriptionProvider: TranscriptionProvider {
    private var asrManager: AsrManager?
    private var modelsDirectory: URL
    private let log = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "Parakeet")

    init(modelsDirectory: URL? = nil) {
        if let dir = modelsDirectory {
            self.modelsDirectory = dir
        } else {
            // Prefer any discovered existing install
            self.modelsDirectory = ParakeetManager.effectiveModelsDirectory
        }
    }

    private func ensureModelsLoaded() async throws {
        if asrManager != nil { return }
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        // If models exist in a different known location, prefer that
        let discovered = ParakeetManager.effectiveModelsDirectory
        if discovered != modelsDirectory { modelsDirectory = discovered }
        log.notice("[Parakeet] ensureModelsLoaded dir=\(self.modelsDirectory.path, privacy: .public)")
        AppLog.dictation.log("[Parakeet] ensureModelsLoaded dir=\(self.modelsDirectory.path)")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        log.notice("[Parakeet] dir contents count=\(contents.count, privacy: .public) items=\(String(describing: contents.prefix(5)), privacy: .public)")
        AppLog.dictation.log("[Parakeet] contents count=\(contents.count) items=\(String(describing: contents.prefix(5)))")
        let inv = ParakeetManager.inventory(at: modelsDirectory)
        log.notice("[Parakeet] compiled models=\(String(describing: inv.mlmodelc), privacy: .public) others=\(String(describing: inv.others.prefix(5)), privacy: .public)")
        AppLog.dictation.log("[Parakeet] compiled=\(String(describing: inv.mlmodelc)) others=\(String(describing: inv.others.prefix(5)))")
        let validation = ParakeetManager.validateModels(at: modelsDirectory)
        if !validation.ok {
            log.notice("[Parakeet] validation missing=\(String(describing: validation.missing), privacy: .public)")
            AppLog.dictation.error("[Parakeet] validation missing=\(String(describing: validation.missing))")
        }
        // Prefer downloading to our directory, but if the package ignores it, fall back
        let models: AsrModels
        do {
            models = try await AsrModels.downloadAndLoad(to: modelsDirectory)
        } catch {
            log.notice("[Parakeet] downloadAndLoad(to:) failed: \(error.localizedDescription, privacy: .public). Retrying with default location…")
            AppLog.dictation.error("[Parakeet] downloadAndLoad(to:) failed: \(error.localizedDescription)")
            models = try await AsrModels.downloadAndLoad()
        }
        let mgr = AsrManager(config: .default)
        try await mgr.initialize(models: models)
        #if compiler(>=5.9)
        // Best-effort signal
        if let available = (try? Mirror(reflecting: mgr).descendant("isAvailable")) as? Bool {
            log.notice("[Parakeet] manager available=\(available, privacy: .public)")
            AppLog.dictation.log("[Parakeet] manager available=\(available)")
        }
        #endif
        asrManager = mgr
    }

    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        try await ensureModelsLoaded()
        guard let mgr = asrManager else { throw ProviderError.notImplemented }
        var samples: [Float]
        do {
            samples = try Self.decodeAudioToFloatMono16k(url: fileURL)
        } catch {
            let ns = error as NSError
            AppLog.dictation.error("[Parakeet] AVAudioFile decode failed domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            // Fallback: try AVAssetReader-based decode
            if let alt = try? Self.decodeWithAssetReader(url: fileURL) {
                AppLog.dictation.log("[Parakeet] Fallback decode via AVAssetReader succeeded: samples=\(alt.count)")
                samples = alt
            } else {
                AppLog.dictation.error("[Parakeet] Fallback decode via AVAssetReader failed")
                throw error
            }
        }
        // Front-end conditioning (configurable via UserDefaults)
        let defaults = UserDefaults.standard
        let hpHz = defaults.object(forKey: "parakeet.highpass.hz") as? Int ?? 60
        if hpHz > 0 { samples = Self.highPass(samples, cutoffHz: Double(hpHz), sampleRate: 16_000) }
        let preEnabled = defaults.object(forKey: "parakeet.preemphasis") as? Bool ?? true
        if preEnabled { samples = Self.preEmphasis(samples, coeff: 0.97) }
        let targetRMS = defaults.object(forKey: "parakeet.rms.target") as? Double ?? 0.06
        samples = Self.normalizeRMS(samples, targetRMS: targetRMS, peakLimit: 0.5, maxGain: 8.0)
        let stats = Self.stats(samples: samples)
        log.notice("[Parakeet] transcribe samples=\(samples.count, privacy: .public) meanAbs=\(stats.meanAbs, format: .fixed(precision: 4)) peak=\(stats.peak, format: .fixed(precision: 4))")
        AppLog.dictation.log("[Parakeet] samples=\(samples.count) meanAbs=\(String(format: "%.4f", stats.meanAbs)) peak=\(String(format: "%.4f", stats.peak))")
        if samples.count < 16_000 {
            let err = NSError(domain: "Parakeet", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Audio too short for ASR (need >= 1s)"])
            log.notice("[Parakeet] rejecting: \(err.localizedDescription, privacy: .public)")
            AppLog.dictation.error("[Parakeet] \(err.localizedDescription)")
            throw err
        }
        if stats.meanAbs < 0.002 && stats.peak < 0.01 {
            let err = NSError(domain: "Parakeet", code: -1002, userInfo: [NSLocalizedDescriptionKey: "Audio appears near-silent; check microphone and input gain"])
            log.notice("[Parakeet] rejecting: \(err.localizedDescription, privacy: .public)")
            AppLog.dictation.error("[Parakeet] \(err.localizedDescription)")
            throw err
        }
        let result: ASRResult
        do {
            result = try await mgr.transcribe(samples)
        } catch {
            let ns = error as NSError
            log.notice("[Parakeet] mgr.transcribe error=\(ns.localizedDescription, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
            AppLog.dictation.error("[Parakeet] transcribe error domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
            throw error
        }
        let preview = result.text.prefix(120)
        log.notice("[Parakeet] result length=\(result.text.count, privacy: .public) preview=\(String(preview), privacy: .public)")
        AppLog.dictation.log("[Parakeet] result length=\(result.text.count) preview=\(String(preview))")
        // Keep models warm for subsequent transcriptions to avoid re-initialization errors
        return result.text
    }

    // Decode arbitrary audio to mono 16k Float32 samples
    private static func decodeAudioToFloatMono16k(url: URL) throws -> [Float] {
        let inputFile = try AVAudioFile(forReading: url)
        let inFormat = inputFile.processingFormat
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        var samples: [Float] = []
        if inFormat == outFormat {
            // Fast path: read directly
            let capacity: AVAudioFrameCount = 4096
            while true {
                let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)!
                try inputFile.read(into: buf, frameCount: capacity)
                if buf.frameLength == 0 { break }
                let ptr = buf.floatChannelData![0]
                samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(buf.frameLength)))
            }
        } else {
            // Convert
            guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
                throw NSError(domain: "Parakeet", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio format conversion failed"])
            }
            let inputFrameCapacity: AVAudioFrameCount = 4096
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inputFrameCapacity)!
            while true {
                try inputFile.read(into: inputBuffer, frameCount: inputFrameCapacity)
                if inputBuffer.frameLength == 0 { break }
                var inputDone = false
                let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192)!
                let status = converter.convert(to: outputBuffer, error: nil, withInputFrom: { inNumPackets, outStatus in
                    if inputDone {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    outStatus.pointee = .haveData
                    inputDone = true
                    return inputBuffer
                })
                if status == .haveData, let ptr = outputBuffer.floatChannelData?[0] {
                    samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(outputBuffer.frameLength)))
                }
                inputBuffer.frameLength = 0
            }
        }
        return samples
    }

    private static func stats(samples: [Float]) -> (meanAbs: Double, peak: Double) {
        guard !samples.isEmpty else { return (0, 0) }
        var sum: Double = 0
        var peak: Double = 0
        for s in samples {
            let a = abs(Double(s))
            sum += a
            if a > peak { peak = a }
        }
        return (sum / Double(samples.count), peak)
    }

    // First-order high-pass filter
    private static func highPass(_ input: [Float], cutoffHz: Double, sampleRate: Double) -> [Float] {
        guard !input.isEmpty else { return input }
        let rc = 1.0 / (2.0 * Double.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        let alpha = rc / (rc + dt)
        var out = Array(repeating: Float(0), count: input.count)
        var yPrev = 0.0
        var xPrev = 0.0
        for i in 0..<input.count {
            let x = Double(input[i])
            let y = alpha * (yPrev + x - xPrev)
            out[i] = Float(y)
            yPrev = y
            xPrev = x
        }
        return out
    }

    // Simple pre-emphasis
    private static func preEmphasis(_ input: [Float], coeff: Float) -> [Float] {
        guard !input.isEmpty else { return input }
        var out = input
        var prev: Float = 0
        for i in 0..<out.count {
            let cur = out[i]
            out[i] = cur - coeff * prev
            prev = cur
        }
        return out
    }

    private static func normalizeRMS(_ input: [Float], targetRMS: Double, peakLimit: Double, maxGain: Double) -> [Float] {
        guard !input.isEmpty else { return input }
        // Compute RMS and peak
        var sumSq: Double = 0
        var peak: Double = 0
        for v in input {
            let d = Double(v)
            sumSq += d * d
            let a = abs(d)
            if a > peak { peak = a }
        }
        let rms = sqrt(sumSq / Double(input.count))
        if rms <= 0 { return input }
        var gain = targetRMS / rms
        // Respect peak limit
        if peak * gain > peakLimit { gain = peakLimit / max(peak, 1e-9) }
        gain = min(gain, maxGain)
        if abs(gain - 1.0) < 1e-3 { return input }
        var out = input
        for i in 0..<out.count {
            let v = Double(out[i]) * gain
            out[i] = Float(max(-1.0, min(1.0, v)))
        }
        return out
    }

    // Robust decode path using AVAssetReader
    private static func decodeWithAssetReader(url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(domain: "Parakeet", code: -2, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw NSError(domain: "Parakeet", code: -3, userInfo: [NSLocalizedDescriptionKey: "AssetReader failed to start: \(String(describing: reader.error))"])
        }
        var samples: [Float] = []
        while reader.status == .reading {
            if let sbuf = output.copyNextSampleBuffer(), let bbuf = CMSampleBufferGetDataBuffer(sbuf) {
                var length: Int = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                if CMBlockBufferGetDataPointer(bbuf, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr, let dataPointer {
                    let count = length / MemoryLayout<Float>.size
                    let ptr = dataPointer.withMemoryRebound(to: Float.self, capacity: count) { $0 }
                    samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
                }
                CMSampleBufferInvalidate(sbuf)
            } else {
                break
            }
        }
        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "Parakeet", code: -4, userInfo: [NSLocalizedDescriptionKey: "AssetReader failed"])
        }
        return samples
    }
}
#else
final class ParakeetTranscriptionProvider: TranscriptionProvider {
    init(modelsDirectory: URL? = nil) {}
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        throw ProviderError.notImplemented
    }
}
#endif
