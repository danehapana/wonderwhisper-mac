import AppKit
import Combine

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []
    private weak var vm: DictationViewModel?

    init(viewModel: DictationViewModel) {
        self.vm = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.image = Self.dotImage(color: .systemGray, diameter: 10)
            button.toolTip = "WonderWhisper"
            button.target = self
            button.action = #selector(toggleDictation)
        }

        // Observe recording state
        viewModel.$isRecording
            .sink { [weak self] recording in
                guard let self, let button = self.statusItem.button else { return }
                let color: NSColor = recording ? .systemRed : .systemGray
                button.image = Self.dotImage(color: color, diameter: 10)
                button.toolTip = recording ? "WonderWhisper — Recording" : "WonderWhisper — Idle"
            }
            .store(in: &cancellables)
    }

    @objc private func toggleDictation() {
        vm?.toggle()
    }

    private static func dotImage(color: NSColor, diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(ovalIn: rect)
        color.setFill()
        path.fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
