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

    // Settings
    var useFnGlobe: Bool = false { didSet { updateFnTap() } }
    var registeredShortcut: Shortcut? { didSet { registerCarbonHotkey() } }

    // MARK: - Carbon Global Hotkey (standard key combos)
    private func registerCarbonHotkey() {
        unregisterCarbonHotkey()
        guard let shortcut = registeredShortcut else { return }

        // Install the event handler once
        if eventHandlerRef == nil {
            var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let callback: EventHandlerUPP = { (_, evtRef, userData) -> OSStatus in
                let selfRef = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
                selfRef.onActivate?()
                return noErr
            }
            let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &eventHandlerRef)
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
            if fnOn && !manager.lastFnFlagsOn {
                // Fn pressed
                manager.onActivate?()
            }
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

