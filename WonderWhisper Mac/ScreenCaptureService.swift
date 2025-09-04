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

    private func captureActiveWindowImage() async -> NSImage? {
        do {
            let content = try await SCShareableContent.current
            guard let window = frontmostWindow(in: content) else { return nil }
            let filter = try SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            // Target a modest resolution for OCR and speed
            let size = window.frame.size
            config.width = Int(size.width.clamped(to: 200...1800))
            config.height = Int(size.height.clamped(to: 150...1400))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 1

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            var captured: NSImage?
            let output = OneShotOutput { sample in
                if let px = CMSampleBufferGetImageBuffer(sample) {
                    let ci = CIImage(cvPixelBuffer: px)
                    let ctx = CIContext(options: nil)
                    if let cg = ctx.createCGImage(ci, from: ci.extent) {
                        captured = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    }
                }
            }
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
            try await stream.startCapture()
            // Wait briefly for a frame
            try? await Task.sleep(nanoseconds: 120_000_000)
            try await stream.stopCapture()
            return captured
        } catch {
            return nil
        }
    }

    private func recognizeText(from image: NSImage) async -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { request, error in
                if let _ = error { cont.resume(returning: nil); return }
                guard let observations = request.results as? [VNRecognizedTextObservation] else { cont.resume(returning: nil); return }
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                cont.resume(returning: text.isEmpty ? nil : text)
            }
            req.recognitionLevel = .fast
            req.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([req]) } catch { cont.resume(returning: nil) }
        }
    }

    func captureActiveWindowText() async -> String? {
        // Try to prompt for Screen Recording permission on first attempt
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        guard let img = await captureActiveWindowImage() else { return nil }
        return await recognizeText(from: img)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
