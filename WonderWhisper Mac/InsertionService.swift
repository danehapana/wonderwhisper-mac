import Foundation
import AppKit
import Carbon.HIToolbox

final class InsertionService {
    var useAXInsertion: Bool = false

    func insert(_ text: String) {
        // Strategy 1: AX direct insertion when enabled
        if useAXInsertion, setFocusedAXValue(text) {
            AppLog.insertion.log("AX insertion succeeded")
            return
        }
        // Fallback: pasteboard + Command-V
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        AppLog.insertion.log("Fallback paste + Cmd+V")
        synthesizeCmdV()
    }

    private func setFocusedAXValue(_ text: String) -> Bool {
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return false }
        let res = AXUIElementSetAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, text as CFTypeRef)
        return res == .success
    }

    private func synthesizeCmdV() {
        AppLog.insertion.log("Synthesizing Cmd+V")
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyV: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}

