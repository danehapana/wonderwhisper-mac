import Foundation
import AVFoundation

enum AudioPreprocessor {
    // Feature flag: defaults write com.slumdev88.wonderwhisper.WonderWhisper-Mac audio.preprocess.enabled -bool YES
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "audio.preprocess.enabled")
    }
    
    // Smart preprocessing: only apply when beneficial based on audio quality analysis
    static var smartModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "audio.preprocess.smart") // defaults to false for backward compatibility
    }

    // Apply simple, robust steps for ASR clarity:
    // - First‑order high‑pass at 90 Hz to remove rumble
    // - Light pre‑emphasis to improve consonant intelligibility
    // - RMS normalization to target ~ -20 dBFS with peak cap
    // Returns a new 16kHz mono Float32 WAV file URL.
    static func processIfEnabled(_ url: URL) -> URL {
        guard isEnabled else { return url }
        
        // Smart mode: analyze quality first
        if smartModeEnabled {
            do {
                let quality = try analyzeAudioQuality(url)
                if quality.needsProcessing {
                    return try process(url)
                } else {
                    // Audio is already clean, skip processing for better performance
                    return url
                }
            } catch {
                // If analysis fails, fall back to normal processing
                do { return try process(url) } catch { return url }
            }
        } else {
            do { return try process(url) } catch { return url }
        }
    }
    
    // Analyze audio quality to determine if preprocessing is beneficial
    static func analyzeAudioQuality(_ url: URL) throws -> AudioQualityAnalysis {
        var samples = try decodeToFloatMono16k(url: url)
        guard !samples.isEmpty else {
            return AudioQualityAnalysis(needsProcessing: false, snr: 0, hasLowFrequencyNoise: false, peakLevel: 0)
        }
        
        // Analyze key quality metrics
        let snr = estimateSNR(samples)
        let hasLowFreqNoise = detectLowFrequencyNoise(samples)
        let peakLevel = samples.map(abs).max() ?? 0
        let rmsLevel = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        
        let needsProcessing = snr < 15.0 ||  // Poor SNR
                             hasLowFreqNoise ||  // Low frequency rumble
                             peakLevel < 0.1 ||  // Very quiet audio
                             rmsLevel > 0.7      // Over-amplified audio
        
        return AudioQualityAnalysis(
            needsProcessing: needsProcessing,
            snr: snr,
            hasLowFrequencyNoise: hasLowFreqNoise,
            peakLevel: peakLevel
        )
    }
    
    struct AudioQualityAnalysis {
        let needsProcessing: Bool
        let snr: Float           // Signal-to-noise ratio estimate
        let hasLowFrequencyNoise: Bool
        let peakLevel: Float     // Peak amplitude level
    }
    
    // Estimate signal-to-noise ratio using spectral analysis
    private static func estimateSNR(_ samples: [Float]) -> Float {
        // Simple SNR estimation: ratio of signal power to noise floor
        // Take samples in quiet periods (low amplitude) as noise estimate
        let sortedAmplitudes = samples.map(abs).sorted()
        let noiseFloor = sortedAmplitudes.prefix(sortedAmplitudes.count / 4).reduce(0, +) / Float(sortedAmplitudes.count / 4)
        let signalLevel = sortedAmplitudes.suffix(sortedAmplitudes.count / 4).reduce(0, +) / Float(sortedAmplitudes.count / 4)
        
        guard noiseFloor > 0 else { return 40.0 } // Assume good SNR if no measurable noise
        let snr = 20 * log10(signalLevel / noiseFloor)
        return max(0, min(40, snr)) // Clamp to reasonable range
    }
    
    // Detect low-frequency noise/rumble
    private static func detectLowFrequencyNoise(_ samples: [Float]) -> Bool {
        // Simple high-pass filter to isolate low frequencies
        let filtered = highPass(samples, cutoffHz: 120, sampleRate: 16000) // Higher cutoff for detection
        let originalRMS = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        let filteredRMS = sqrt(filtered.map { $0 * $0 }.reduce(0, +) / Float(filtered.count))
        
        // If filtering removes significant energy, there was low-frequency content
        let energyReduction = (originalRMS - filteredRMS) / originalRMS
        return energyReduction > 0.15 // 15% energy in low frequencies indicates rumble
    }

    static func process(_ url: URL) throws -> URL {
        let sr: Double = 16_000
        var samples = try decodeToFloatMono16k(url: url)
        if samples.isEmpty { return url }

        samples = highPass(samples, cutoffHz: 90, sampleRate: sr)
        samples = preEmphasis(samples, coeff: 0.97)
        samples = normalizeRMS(samples, targetRMS: 0.08, peakLimit: 0.98, maxGain: 8.0)

        let outURL = url.deletingPathExtension().appendingPathComponent("").deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_proc").appendingPathExtension("wav")
        try writeFloatMono16kWav(samples: samples, to: outURL)
        return outURL
    }

    // MARK: - DSP helpers
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

    // MARK: - I/O
    private static func decodeToFloatMono16k(url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(domain: "AudioPreprocessor", code: -2, userInfo: [NSLocalizedDescriptionKey: "No audio track found"])
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
            throw NSError(domain: "AudioPreprocessor", code: -3, userInfo: [NSLocalizedDescriptionKey: "Reader failed: \(String(describing: reader.error))"])
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
            throw reader.error ?? NSError(domain: "AudioPreprocessor", code: -4, userInfo: [NSLocalizedDescriptionKey: "Reader failed"])
        }
        return samples
    }

    private static func writeFloatMono16kWav(samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ])
        var offset = 0
        let chunk = 16_000 * 2 // 2 seconds per write
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress {
            buf.floatChannelData![0].update(from: base + offset, count: n)
                }
            }
            try file.write(from: buf)
            offset += n
        }
    }
}
