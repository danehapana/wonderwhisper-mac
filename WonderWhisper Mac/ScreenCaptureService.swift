import Foundation
import AppKit
import Vision
import ScreenCaptureKit

final class ScreenCaptureService: NSObject {
    private func frontmostWindow(in content: SCShareableContent) -> SCWindow? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let pid = frontApp?.processIdentifier
        // Prefer frontmost app's on-screen, non-minimized window
        if let pid {
            if let win = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.isOnScreen }) {
                return win
            }
        }
        // Fallback to first on-screen window not owned by us
        let ownPID = NSRunningApplication.current.processIdentifier
        return content.windows.first(where: { $0.owningApplication?.processID != ownPID && $0.isOnScreen })
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
            let content = try await SCShareableContent.current
            guard let window = frontmostWindow(in: content) else { return nil }
            let filter = try SCContentFilter(desktopIndependentWindow: window)
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
            // Configure Vision request once
            let req = VNRecognizeTextRequest { request, _ in }
            req.recognitionLevel = .fast
            req.usesLanguageCorrection = false
            req.recognitionLanguages = ["en-US"]
            // With 1:1 device pixels, typical 12–14pt UI text is ~0.008–0.012 of image height
            req.minimumTextHeight = 0.01
            if #available(macOS 13.0, *) {
                req.revision = VNRecognizeTextRequestRevision3
            }

            let queue = DispatchQueue(label: "ScreenCaptureService.SampleHandler")
            let output = OneShotOutput { sample in
                guard let px = CMSampleBufferGetImageBuffer(sample) else { return }
                let handler = VNImageRequestHandler(cvPixelBuffer: px, options: [:])
                do {
                    try handler.perform([req])
                    if let observations = req.results as? [VNRecognizedTextObservation] {
                        // Build code-friendly, ASCII-heavy text and filter noise
                        let asciiSymbols = " !\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~\t\r\n"
                        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: asciiSymbols))
                        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                            .map { s -> String in
                                let scalars = s.unicodeScalars.filter { allowed.contains($0) }
                                return String(String.UnicodeScalarView(scalars))
                            }
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        if !lines.isEmpty {
                            capturedText = lines.joined(separator: "\n")
                        }
                    }
                } catch {
                    // Ignore OCR errors for one-shot
                }
            }
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            // Wait for the first recognized text or timeout quickly
            let deadline = Date().addingTimeInterval(0.20) // cap ~200 ms
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
