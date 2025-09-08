import Foundation
import AVFoundation

// Deepgram Streaming (v1 listen) – binary PCM16 frames over WebSocket
// Docs: https://developers.deepgram.com/docs/live-streaming-audio
final class DeepgramStreamingProvider: TranscriptionProvider {
  private let apiKey: String
  private let session: URLSession

  // Live state
  private var ws: URLSessionWebSocketTask?
  private var recvTask: Task<Void, Never>?
  private var acc: DeepgramAccumulator?

  init(apiKey: String) {
    self.apiKey = apiKey
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 60
    cfg.timeoutIntervalForResource = 300
    self.session = URLSession(configuration: cfg)
  }

  func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.missingAPIKey }
    try await beginRealtime()
    // Stream file as PCM16 16 kHz mono in ~50ms chunks
    try await streamFileAsPCM16(url: fileURL, sampleRate: 16_000)
    // Close stream; Deepgram finalizes when stream ends
    let text = try await endRealtime()
    return text
  }

  // Live API used by DictationController for mic streaming
  func beginRealtime() async throws {
    guard ws == nil else { return }
    guard let url = URL(string: "wss://api.deepgram.com/v1/listen?model=nova-3&language=en-US&smart_format=true&encoding=linear16&sample_rate=16000&channels=1&endpointing=true") else { throw ProviderError.invalidURL }
    var req = URLRequest(url: url)
    req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
    // Deepgram allows binary PCM; we'll send 16 kHz mono PCM16
    let task = session.webSocketTask(with: req)
    task.resume()
    let acc = DeepgramAccumulator()
    self.acc = acc
    self.ws = task
    self.recvTask = Task { [weak self] in
      await self?.receiveLoop(task: task, accumulator: acc)
    }
  }

  func feedPCM16(_ data: Data) async throws {
    guard let task = ws else { return }
    // Send immediately; Deepgram v1/listen accepts binary after WS open
    try await task.send(.data(data))
  }

  func endRealtime() async throws -> String {
    guard let task = ws, let acc = acc else { return "" }
    // Give a short window for final Results message to arrive
    try? await Task.sleep(nanoseconds: 150_000_000)
    recvTask?.cancel()
    task.cancel(with: .goingAway, reason: nil)
    self.ws = nil
    self.recvTask = nil
    let text = await acc.finalTranscript()
    self.acc = nil
    return text
  }

  // Internal helpers
  private func receiveLoop(task: URLSessionWebSocketTask, accumulator: DeepgramAccumulator) async {
    while true {
      do {
        let message = try await task.receive()
        switch message {
        case .string(let text):
          await accumulator.ingest(jsonText: text)
          // If Deepgram sends keepalive/metadata, continue
        case .data:
          break
        @unknown default:
          break
        }
      } catch {
        break
      }
    }
  }

  private func streamFileAsPCM16(url: URL, sampleRate: Double) async throws {
    guard let task = ws else { return }
    let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    let file = try AVAudioFile(forReading: url)
    let conv = AVAudioConverter(from: file.processingFormat, to: target)!
    let frames: AVAudioFrameCount = 800 // ~50ms @16k
    let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames)!
    var eof = false
    while !eof {
      let ib: AVAudioConverterInputBlock = { n, status in
        do {
          let cap = min(2048, Int(n))
          guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(cap)) else { status.pointee = .noDataNow; return nil }
          try file.read(into: buf)
          if buf.frameLength == 0 { status.pointee = .endOfStream; return nil }
          status.pointee = .haveData
          return buf
        } catch { status.pointee = .endOfStream; return nil }
      }
      out.frameLength = frames
      let st = conv.convert(to: out, error: nil, withInputFrom: ib)
      switch st {
      case .haveData:
        if let ch = out.int16ChannelData {
          let p = ch[0]
          let bytes = UnsafeBufferPointer(start: p, count: Int(out.frameLength))
          let data = Data(buffer: bytes)
          try await task.send(.data(data))
          try await Task.sleep(nanoseconds: 50_000_000)
        }
      case .endOfStream: eof = true
      default: eof = true
      }
    }
  }
}

private actor DeepgramAccumulator {
  private(set) var isOpen: Bool = false
  private var segments: [String] = []
  private var lastFinalTime: Date = Date()

  func ingest(jsonText: String) {
    guard let data = jsonText.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    // Deepgram sends an initial Metadata/open message; treat first message as open
    if obj["type"] as? String == "Metadata" { isOpen = true; return }
    if obj["type"] as? String == "Results" {
      if let channel = obj["channel"] as? [String: Any],
         let alts = channel["alternatives"] as? [[String: Any]],
         let first = alts.first,
         let isFinal = obj["is_final"] as? Bool {
        let text = first["transcript"] as? String ?? ""
        if isFinal == true, !text.isEmpty {
          segments.append(text)
          lastFinalTime = Date()
        }
      }
    }
  }

  func finalTranscript() -> String {
    return segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}


