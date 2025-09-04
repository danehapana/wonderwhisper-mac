import AppKit
import Combine

@MainActor
final class WaveformOverlayController {
    private let window: NSWindow
    private let waveformView = WaveformView()
    private var cancellables: Set<AnyCancellable> = []
    private weak var vm: DictationViewModel?

    init(viewModel: DictationViewModel) {
        self.vm = viewModel
        let size = NSSize(width: 110, height: 18)
        let rect = NSRect(origin: .zero, size: size)
        let w = NSPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.hasShadow = false
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.contentView = waveformView
        self.window = w

        // Start hidden
        window.alphaValue = 0
        positionAtTopCenter()
        window.orderFrontRegardless()

        // React to recording state
        viewModel.$isRecording
            .removeDuplicates()
            .sink { [weak self] rec in
                guard let self else { return }
                if rec {
                    self.positionAtTopCenter()
                    self.animateIn()
                    self.waveformView.startAnimating()
                } else {
                    self.waveformView.stopAnimating()
                    self.animateOut()
                }
            }
            .store(in: &cancellables)

        viewModel.$audioLevel
            .sink { [weak self] level in
                self?.waveformView.setLevel(CGFloat(level))
            }
            .store(in: &cancellables)

        // Reposition on screen changes
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.positionAtTopCenter()
        }
    }

    private func positionAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let x = screen.frame.midX - window.frame.width / 2
        // Place just below menu bar area
        let y = vf.origin.y + vf.height - window.frame.height - 6
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func animateIn() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            var f = window.frame
            f.origin.y -= 8
            window.setFrame(f, display: false)
            window.animator().alphaValue = 1
            // restore to final position
            positionAtTopCenter()
        }
        window.orderFrontRegardless()
    }

    private func animateOut() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            var f = window.frame
            f.origin.y += 8
            window.animator().setFrameOrigin(f.origin)
            window.animator().alphaValue = 0
        }
    }
}

private final class WaveformView: NSView {
    private var barLayers: [CALayer] = []
    private var timer: Timer?
    private let barCount = 28
    private var level: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        layer?.cornerRadius = 7
        isHidden = false
        buildBars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutBars()
    }

    func startAnimating() {
        stopAnimating()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        // Set to a calm state
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in barLayers {
            var r = layer.frame
            r.size.height = bounds.height * 0.28
            r.origin.y = (bounds.height - r.size.height) / 2
            layer.frame = r
            layer.backgroundColor = NSColor.systemRed.cgColor
        }
        CATransaction.commit()
    }

    private func buildBars() {
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        guard let root = layer else { return }
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.cornerRadius = 1
            bar.backgroundColor = NSColor.systemRed.cgColor
            root.addSublayer(bar)
            barLayers.append(bar)
        }
        layoutBars()
    }

    private func layoutBars() {
        guard !barLayers.isEmpty else { return }
        let insetX: CGFloat = 8
        let insetY: CGFloat = 4
        let availableWidth = bounds.width - insetX * 2
        let availableHeight = bounds.height - insetY * 2
        let spacing: CGFloat = 1
        let barWidth = max(1.0, (availableWidth - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
        var x = insetX
        for bar in barLayers {
            let h = availableHeight * 0.3
            bar.frame = NSRect(x: x, y: (bounds.height - h)/2, width: barWidth, height: h)
            x += barWidth + spacing
        }
    }

    private func tick() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        let minH: CGFloat = 2
        let maxH = bounds.height - 4
        let now = CFAbsoluteTimeGetCurrent()
        for (i, bar) in barLayers.enumerated() {
            // Level-driven amplitude with slight per-bar modulation
            let phase = CGFloat(i) * 0.22
            let wobble = 0.12 * sin(now * 8 + Double(phase))
            // Emphasize differences at low-to-mid levels for visible motion
            let boosted = pow(max(0, min(1, level)), 0.7)
            let amp = max(0, min(1, boosted + wobble))
            let h = minH + (maxH - minH) * amp
            var r = bar.frame
            r.size.height = h
            r.origin.y = (bounds.height - h)/2
            bar.frame = r
        }
        CATransaction.commit()
    }

    func setLevel(_ value: CGFloat) {
        // Smooth with a slightly faster low-pass for responsiveness
        let alpha: CGFloat = 0.45
        level = level * (1 - alpha) + value * alpha
    }
}
