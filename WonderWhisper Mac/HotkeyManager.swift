import Foundation
import Carbon.HIToolbox
import Cocoa
import ApplicationServices

final class HotkeyManager {
    struct Shortcut: Equatable, Codable {
        var keyCode: UInt32 // kVK_ constants (e.g., 49 for Space)
        var modifiers: UInt32 // Carbon modifier mask: cmdKey, optionKey, controlKey, shiftKey
    }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFnFlagsOn: Bool = false

    var onActivate: (() -> Void)?

    // Push-to-talk timing
    private var hotkeyPressStart: Date?
    private let briefPressThreshold: TimeInterval = 0.8

    // Settings
    var useFnGlobe: Bool = false { didSet { updateFnTap() } }
    var registeredShortcut: Shortcut? { didSet { registerCarbonHotkey() } }

    // MARK: - Carbon Global Hotkey (standard key combos)
    private func registerCarbonHotkey() {
        unregisterCarbonHotkey()
        guard let shortcut = registeredShortcut else { return }

        // Install the event handler once
        if eventHandlerRef == nil {
            var specs: [EventTypeSpec] = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            let callback: EventHandlerUPP = { (_, evtRef, userData) -> OSStatus in
                let selfRef = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
                let kind = GetEventKind(evtRef)
                if kind == UInt32(kEventHotKeyPressed) {
                    selfRef.handleHotkeyDown()
                } else if kind == UInt32(kEventHotKeyReleased) {
                    selfRef.handleHotkeyUp()
                }
                return noErr
            }
            let target = GetApplicationEventTarget()
            let userPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            let status: OSStatus = specs.withUnsafeBufferPointer { buf in
                InstallEventHandler(target, callback, Int(buf.count), buf.baseAddress, userPtr, &eventHandlerRef)
            }
            guard status == noErr else { return }
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x57574854), id: 1) // 'WWHT'
        var hkRef: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hkRef)
        if status == noErr, let hkRef {
            self.hotKeyRef = hkRef
        }
    }

    private func unregisterCarbonHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        // Keep handler installed for lifetime
    }

    // MARK: - Fn/Globe via Accessibility event tap
    private func updateFnTap() {
        if useFnGlobe {
            startFnTap()
        } else {
            stopFnTap()
        }
    }

    private func startFnTap() {
        if eventTap != nil { return }
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { (proxy, type, event, userInfo) -> Unmanaged<CGEvent>? in
            guard type == .flagsChanged, let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            let flags = event.flags
            let fnOn = flags.contains(.maskSecondaryFn)
            if fnOn && !manager.lastFnFlagsOn { manager.handleHotkeyDown() }
            if !fnOn && manager.lastFnFlagsOn { manager.handleHotkeyUp() }
            manager.lastFnFlagsOn = fnOn
            return Unmanaged.passUnretained(event)
        }, userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())) else {
            // Likely missing Accessibility permission
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let src = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func stopFnTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        lastFnFlagsOn = false
    }

    // MARK: - Helpers
    private func handleHotkeyDown() {
        hotkeyPressStart = Date()
        onActivate?() // Start recording immediately or toggle if already recording
    }

    private func handleHotkeyUp() {
        guard let start = hotkeyPressStart else { return }
        hotkeyPressStart = nil
        let duration = Date().timeIntervalSince(start)
        if duration >= briefPressThreshold {
            // Held long enough: push-to-talk ends on release
            onActivate?()
        } else {
            // Short tap: hands-free mode (stay recording); next press will toggle stop
        }
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }

    deinit {
        unregisterCarbonHotkey()
        stopFnTap()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }
}
