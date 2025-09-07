import Foundation
import AppKit
import Vision
import ScreenCaptureKit
import OSLog

final class ScreenCaptureService: NSObject {
    private static let signposter = OSSignposter(logger: AppLog.ocr)
    private func frontmostWindow(in content: SCShareableContent) -> SCWindow? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let pid = frontApp?.processIdentifier
        // Prefer the largest on-screen window for the frontmost app to avoid selecting tiny overlays/panels
        if let pid {
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen }
            if let best = candidates
                .filter({ $0.frame.width >= 300 && $0.frame.height >= 200 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return best
            }
            // If all are small (overlays), still pick the largest visible one
            if let anyBest = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return anyBest
            }
        }
        // Fallback to the largest on-screen window not owned by us
        let ownPID = NSRunningApplication.current.processIdentifier
        let others = content.windows.filter { $0.owningApplication?.processID != ownPID && $0.isOnScreen }
        return others.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    private final class OneShotOutput: NSObject, SCStreamOutput {
        let onFrame: (CMSampleBuffer) -> Void
        init(onFrame: @escaping (CMSampleBuffer) -> Void) { self.onFrame = onFrame }
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
            guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
            onFrame(sampleBuffer)
        }
    }

    // Capture a single frame and OCR directly from the CVPixelBuffer
    private func captureAndRecognizeActiveWindowText() async -> String? {
        do {
            let sid = Self.signposter.makeSignpostID()
            let state_sc = Self.signposter.beginInterval("SCShareableContent.current", id: sid)
            let content = try await SCShareableContent.current
            Self.signposter.endInterval("SCShareableContent.current", state_sc)
            guard let window = frontmostWindow(in: content) else { return nil }
            // Heuristics: detect code editors (Cursor, VS Code, JetBrains, Xcode)
            let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let isCodeEditor = [
                // Cursor
                "com.cursorai.cursor",
                "com.todesktop.cursor", // legacy/toDesktop variants
                // VS Code
                "com.microsoft.VSCode",
                "com.microsoft.VSCodeInsiders",
                // Xcode
                "com.apple.dt.Xcode",
                // JetBrains IDEs (common prefix)
                "com.jetbrains"
            ].contains(where: { frontBundle.hasPrefix($0) })
            let preferAccurate = (UserDefaults.standard.object(forKey: "ocr.accurateForEditors") as? Bool ?? true)
            let shouldPreferAccurate = isCodeEditor && preferAccurate
            if UserDefaults.standard.bool(forKey: "ocr.debug") {
                let title = window.title ?? "(no title)"
                let f = window.frame
                let bid = window.owningApplication?.bundleIdentifier ?? "(unknown)"
                #if DEBUG
                print("[OCR] chosen window title=\(title) size=\(Int(f.width))x\(Int(f.height)) app=\(bid)")
                #endif
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let size = window.frame.size
            // Capture at (approx) 1:1 device pixels to avoid blurring text
            let scale = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0
            config.width = max(1, Int((size.width * scale).rounded()))
            config.height = max(1, Int((size.height * scale).rounded()))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 1

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            var capturedText: String?
            // Prepare two OCR requests: a fast pass and an accurate fallback
            let fastReq = VNRecognizeTextRequest { _, _ in }
            fastReq.recognitionLevel = shouldPreferAccurate ? .accurate : .fast
            fastReq.usesLanguageCorrection = !shouldPreferAccurate
            // Allow Vision to auto-detect languages (no explicit list)
            // Disable minimum text height by default (can be overridden via UserDefaults)
            let userMinH = UserDefaults.standard.object(forKey: "ocr.minimumTextHeight") as? Double
            let finalFast = Float(userMinH ?? 0.0)
            fastReq.minimumTextHeight = max(0.0, finalFast)
            let minHFast = finalFast
            if #available(macOS 13.0, *) {
                fastReq.revision = VNRecognizeTextRequestRevision3
            }

            let accurateReq = VNRecognizeTextRequest { _, _ in }
            accurateReq.recognitionLevel = .accurate
            accurateReq.usesLanguageCorrection = !isCodeEditor
            // Allow Vision to auto-detect languages (no explicit list)
            let finalAcc = Float(userMinH ?? 0.0)
            accurateReq.minimumTextHeight = max(0.0, finalAcc)
            let minHAcc = finalAcc
            if #available(macOS 13.0, *) {
                accurateReq.revision = VNRecognizeTextRequestRevision3
            }

            let queue = DispatchQueue(label: "ScreenCaptureService.SampleHandler", qos: .userInitiated)
            let output = OneShotOutput { sample in
                guard let px = CMSampleBufferGetImageBuffer(sample) else { return }
                // Helper to evaluate text quality (confidence only; no ASCII filtering)
                func qualityScore(_ observations: [VNRecognizedTextObservation]?) -> (score: Double, text: String?) {
                    guard let observations else { return (0, nil) }
                    var totalConfidence: Double = 0
                    var count: Double = 0
                    var raw = ""
                    for obs in observations {
                        guard let top = obs.topCandidates(1).first else { continue }
                        totalConfidence += Double(top.confidence)
                        count += 1
                        raw.append(top.string)
                        raw.append("\n")
                    }
                    let avgConf = count > 0 ? totalConfidence / count : 0
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (avgConf, text.isEmpty ? nil : text)
                }

                do {
                    let handler = VNImageRequestHandler(cvPixelBuffer: px, options: [:])
                    let sid = Self.signposter.makeSignpostID()
                    let state_fast = Self.signposter.beginInterval("OCR.fast", id: sid)
                    try handler.perform([fastReq])
                    Self.signposter.endInterval("OCR.fast", state_fast)
                    var bestScore: Double = 0
                    var bestText: String? = nil
                    do {
                        let (s, t) = qualityScore(fastReq.results)
                        bestScore = s
                        bestText = t
                    }
                    let lc = bestText?.split(separator: "\n").count ?? 0
                    let cc = bestText?.count ?? 0
                    let goodEnough = (lc >= 15) || (cc >= 200) || (bestScore >= 0.50)
                    if !goodEnough {
                        if bestScore < 0.6 && shouldPreferAccurate {
                            let sid2 = Self.signposter.makeSignpostID()
                            let state_acc = Self.signposter.beginInterval("OCR.accurate", id: sid2)
                            try handler.perform([accurateReq])
                            Self.signposter.endInterval("OCR.accurate", state_acc)
                            let (s2, t2) = qualityScore(accurateReq.results)
                            if s2 > bestScore { bestScore = s2; bestText = t2 }
                        } else if bestScore < 0.30 {
                            // Safety net: even if accurate is off, attempt once when quality is catastrophic
                            let sid2 = Self.signposter.makeSignpostID()
                            let state_acc = Self.signposter.beginInterval("OCR.accurate", id: sid2)
                            try? handler.perform([accurateReq])
                            Self.signposter.endInterval("OCR.accurate", state_acc)
                            let (s2, t2) = qualityScore(accurateReq.results)
                            if s2 > bestScore { bestScore = s2; bestText = t2 }
                        }
                    }
                    // Optional debug: log dimensions and line count for troubleshooting
                    if UserDefaults.standard.bool(forKey: "ocr.debug") {
                        var lineCount = 0
                        if let txt = bestText {
                            lineCount = txt.split(separator: "\n").count
                        }
                        let w = CVPixelBufferGetWidth(px)
                        let h = CVPixelBufferGetHeight(px)
                        #if DEBUG
                        print("[OCR] image=\(w)x\(h) score=\(String(format: "%.2f", bestScore)) lines=\(lineCount) editor=\(isCodeEditor) accurate=\(shouldPreferAccurate) minFast=\(String(format: "%.4f", minHFast)) minAcc=\(String(format: "%.4f", minHAcc))")
                        #endif
                    }
                    if let text = bestText, !text.isEmpty {
                        capturedText = text
                    }
                } catch {
                    // Ignore OCR errors for one-shot
                }
            }
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            // Wait for the first recognized text or timeout quickly
            let baseTimeout: TimeInterval = shouldPreferAccurate ? 0.60 : 0.17
            let deadline = Date().addingTimeInterval(baseTimeout)
            while capturedText == nil && Date() < deadline {
                try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms slices
                if capturedText != nil { break }
            }
            try await stream.stopCapture()
            return capturedText
        } catch {
            return nil
        }
    }

    func captureActiveWindowText() async -> String? {
        // Try to prompt for Screen Recording permission on first attempt
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        return await captureAndRecognizeActiveWindowText()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
