import Foundation
import AVFoundation

final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private(set) var isRecording: Bool = false

    func startRecording() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "dictation_\(UUID().uuidString).m4a"
        let url = tempDir.appendingPathComponent(filename)

        // AAC mono at 16kHz keeps files small and is widely accepted
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        guard recorder?.prepareToRecord() == true else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "prepareToRecord failed"])
        }
        recorder?.record()
        isRecording = true
        return url
    }

    func stopRecording() -> URL? {
        guard isRecording, let recorder else { return nil }
        recorder.stop()
        isRecording = false
        return recorder.url
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {}

