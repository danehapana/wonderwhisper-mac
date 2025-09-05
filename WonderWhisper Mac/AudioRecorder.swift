import Foundation
import AVFoundation

final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private(set) var isRecording: Bool = false
    var onLevel: ((Float) -> Void)?
    private var previousDefaultInputUID: String?
    private var finishContinuation: CheckedContinuation<URL?, Never>?

    func startRecording() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "dictation_\(UUID().uuidString).wav"
        let url = tempDir.appendingPathComponent(filename)

        // WAV PCM Float32 mono at 16kHz for best ASR compatibility
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]

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

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Resume any waiter with the final URL (even if not successful, caller can decide)
        if let c = finishContinuation { finishContinuation = nil; c.resume(returning: recorder.url) }
    }
}
