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
            button.image = Self.letterWImage(color: .labelColor)
            button.toolTip = "WonderWhisper"
        }
        statusItem.menu = buildMenu()

        // Observe recording state
        viewModel.$isRecording
            .sink { [weak self] recording in
                guard let self, let button = self.statusItem.button else { return }
                let color: NSColor = recording ? .systemRed : .labelColor
                button.image = Self.letterWImage(color: color)
                button.toolTip = recording ? "WonderWhisper — Recording" : "WonderWhisper — Idle"
                // Rebuild to update checkmarks etc. if needed
                self.statusItem.menu = self.buildMenu()
            }
            .store(in: &cancellables)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Toggle Dictation", action: #selector(menuToggleDictation), keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = [.command, .option]
        toggle.target = self
        menu.addItem(toggle)

        let addDict = NSMenuItem(title: "Add to Dictionary", action: #selector(addClipboardToVocabulary), keyEquivalent: "")
        addDict.target = self
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        addDict.isEnabled = !clip.isEmpty
        menu.addItem(addDict)

        menu.addItem(.separator())

        let inputMenu = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // System default
        let currentSelection = AudioInputSelection.load()
        let sysItem = NSMenuItem(title: "System Default", action: #selector(selectSystemDefault), keyEquivalent: "")
        sysItem.target = self
        sysItem.state = (currentSelection == .systemDefault) ? .on : .off
        sub.addItem(sysItem)

        // Devices
        let devices = AudioDeviceManager.availableInputDevices()
        if devices.isEmpty == false { sub.addItem(.separator()) }
        for dev in devices {
            let item = NSMenuItem(title: dev.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.representedObject = dev.uid
            item.target = self
            if case .deviceUID(let uid) = currentSelection, uid == dev.uid { item.state = .on }
            sub.addItem(item)
        }
        inputMenu.submenu = sub
        menu.addItem(inputMenu)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WonderWhisper", action: #selector(quitApp), keyEquivalent: "q"))
        return menu
    }

    @objc private func menuToggleDictation() { vm?.toggle() }
    @objc private func selectSystemDefault() {
        AudioInputSelection.systemDefault.persist()
        statusItem.menu = buildMenu()
    }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String { AudioInputSelection.deviceUID(uid).persist() }
        statusItem.menu = buildMenu()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func addClipboardToVocabulary() {
        guard let vm = vm else { return }
        guard var word = NSPasteboard.general.string(forType: .string) else { return }
        word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        // Split existing vocabulary by comma/newline, normalize and dedupe
        let separators = CharacterSet(charactersIn: ",\n\r")
        var items = vm.vocabCustom
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let lowered = Set(items.map { $0.lowercased() })
        if !lowered.contains(word.lowercased()) {
            items.append(word)
            vm.vocabCustom = items.joined(separator: "\n")
        }
        statusItem.menu = buildMenu()
    }

    private static func letterWImage(color: NSColor, size: NSSize = NSSize(width: 18, height: 16)) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: 13, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let str = NSAttributedString(string: "W", attributes: attrs)
        let rect = NSRect(x: 0, y: (size.height - font.capHeight)/2 - 1, width: size.width, height: font.capHeight + 2)
        str.draw(in: rect)
        img.isTemplate = false
        return img
    }
}
