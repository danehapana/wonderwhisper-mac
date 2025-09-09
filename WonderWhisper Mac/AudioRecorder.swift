import Foundation
import AVFoundation

final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private(set) var isRecording: Bool = false
    var onLevel: ((Float) -> Void)?
    private var previousDefaultInputUID: String?
    private var finishContinuation: CheckedContinuation<URL?, Never>?

    // Live streaming support (AVAudioEngine)
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pcmAccumulator = Data()
    private var isStreaming: Bool = false
    private let streamQueue = DispatchQueue(label: "audio.stream.queue", qos: .userInitiated)
    private var onPCM16Frame: ((Data) -> Void)?
    
    // Memory recording removed due to unreliable output

    // MARK: - Audio Format Configuration
    private func audioFormatSettings(format: String) throws -> (filename: String, settings: [String: Any]) {
        switch format {
        case "mp3":
            // Note: macOS doesn't natively support MP3 recording via AVAudioRecorder
            // Fall back to AAC with aggressive compression for similar file sizes
            return ("m4a", [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 16_000 // Aggressive AAC compression = ~2 KB/s, similar to MP3
            ])
        case "ogg":
            // Note: macOS doesn't natively support OGG recording via AVAudioRecorder
            // Fall back to AAC with very low bitrate for similar compression
            return ("m4a", [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 16_000 // Aggressive AAC compression = ~2 KB/s
            ])
        case "aac":
            return ("m4a", [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000 // Original 32 kbps = ~4 KB/s
            ])
        default: // "wav"
            return ("wav", [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
        }
    }

    func startRecording() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let format = UserDefaults.standard.string(forKey: "audio.recording.format") ?? "wav"
        let formatLower = format.lowercased()
        
        // Determine filename and extension based on format
        let (filename, settings) = try audioFormatSettings(format: formatLower)
        let url = tempDir.appendingPathComponent("dictation_\(UUID().uuidString).\(filename)")

        // Recording settings optimized for speech transcription at 16kHz mono

        // If a specific input device was selected, optionally switch system default temporarily
        if UserDefaults.standard.bool(forKey: "audio.switchSystemDefault") {
            switch AudioInputSelection.load() {
            case .systemDefault:
                break
            case .deviceUID(let uid):
                previousDefaultInputUID = AudioDeviceManager.currentDefaultInputUID()
                _ = AudioDeviceManager.setSystemDefaultInput(toUID: uid)
            }
        }

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.isMeteringEnabled = true
        guard recorder?.prepareToRecord() == true else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "prepareToRecord failed"])
        }
        recorder?.record()
        isRecording = true
        startLevelUpdates()
        // Raise input gain asynchronously to avoid delaying recording start
        DispatchQueue.global(qos: .userInitiated).async {
            _ = AudioDeviceManager.raiseInputVolumeIfNeeded(for: AudioInputSelection.load())
        }
        return url
    }

    func stopRecording() -> URL? {
        guard isRecording, let recorder else { return nil }
        recorder.stop()
        isRecording = false
        stopLevelUpdates()
        // Restore previous default input device if we changed it
        if UserDefaults.standard.bool(forKey: "audio.switchSystemDefault") {
            if let prev = previousDefaultInputUID {
                _ = AudioDeviceManager.setSystemDefaultInput(toUID: prev)
                previousDefaultInputUID = nil
            }
        }
        return recorder.url
    }

    // Wait until AVAudioRecorder flushes and finishes writing before returning the URL
    func stopRecordingAndWait() async -> URL? {
        guard isRecording, let recorder else { return nil }
        let url = recorder.url
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            finishContinuation = cont
            self.recorder?.stop()
            isRecording = false
            stopLevelUpdates()
            // Restore previous default input device if we changed it
            if UserDefaults.standard.bool(forKey: "audio.switchSystemDefault") {
                if let prev = previousDefaultInputUID {
                    _ = AudioDeviceManager.setSystemDefaultInput(toUID: prev)
                    previousDefaultInputUID = nil
                }
            }
            // In case the delegate doesn't fire (shouldn't happen), provide a safety timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                if let c = self.finishContinuation { self.finishContinuation = nil; c.resume(returning: url) }
            }
        }
    }

    private func startLevelUpdates() {
        stopLevelUpdates()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self = self, let r = self.recorder else { return }
            r.updateMeters()
            let avg = r.averagePower(forChannel: 0)
            let peak = r.peakPower(forChannel: 0)
            // Use the more reactive of the two
            let level = max(Self.normalize(power: avg), Self.normalize(power: peak))
            self.onLevel?(level)
        }
        if let t = levelTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = nil
        onLevel?(0)
    }

    private static func normalize(power: Float) -> Float {
        // Map dB (-160..0) to 0..1, with floor at -50 dB for better responsiveness
        let minDb: Float = -50
        let clamped = max(power, minDb)
        let range = minDb * -1
        let norm = (clamped + range) / range // 0..1 linear
        // Slight easing to emphasize small signals
        return pow(norm, 1.1)
    }
}

// Memory recording extension removed - was causing unreliable transcription output

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Resume any waiter with the final URL (even if not successful, caller can decide)
        if let c = finishContinuation { finishContinuation = nil; c.resume(returning: recorder.url) }
    }
}

// MARK: - Live Streaming (PCM16 16 kHz mono)
extension AudioRecorder {
    func startStreamingPCM16(onFrame: @escaping (Data) -> Void) throws {
        guard !isStreaming else { return }
        isStreaming = true
        self.onPCM16Frame = onFrame

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        pcmAccumulator.removeAll(keepingCapacity: true)

        // 50ms at 16kHz = 800 samples (mono) = 1600 bytes
        let chunkBytes = 800 * 2

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = self.converter else { return }
            // Prepare output buffer with a reasonable capacity
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(1600)) else { return }
            outBuffer.frameLength = 0

            let status = converter.convert(to: outBuffer, error: nil, withInputFrom: { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            })

            if status == .haveData, let channel = outBuffer.int16ChannelData {
                let samples = channel[0]
                let frames = Int(outBuffer.frameLength)
                let bytes = UnsafeBufferPointer(start: samples, count: frames)
                let data = Data(buffer: bytes)
                self.pcmAccumulator.append(data)

                while self.pcmAccumulator.count >= chunkBytes {
                    let chunk = self.pcmAccumulator.prefix(chunkBytes)
                    self.pcmAccumulator.removeFirst(chunkBytes)
                    let chunkData = Data(chunk)
                    self.streamQueue.async { [onFrame] in
                        onFrame(chunkData)
                    }
                }
            }
        }

        try engine.start()
    }

    func stopStreamingPCM16() {
        guard isStreaming else { return }
        isStreaming = false
        if let input = engine?.inputNode { input.removeTap(onBus: 0) }
        engine?.stop()
        engine = nil
        converter = nil
        pcmAccumulator.removeAll()
        onPCM16Frame = nil
    }
}
