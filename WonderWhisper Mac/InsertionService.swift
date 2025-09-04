import Foundation
import AppKit
import Carbon.HIToolbox

final class InsertionService {
    var useAXInsertion: Bool = false

    func insert(_ text: String) {
        // Special-case: if our app is frontmost, insert directly into the first responder text view
        if let bundleID = Bundle.main.bundleIdentifier,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
           insertIntoFirstResponder(text) {
            AppLog.insertion.log("Direct insert into in-app first responder")
            return
        }
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

    private func insertIntoFirstResponder(_ text: String) -> Bool {
        var success = false
        DispatchQueue.main.sync {
            if let responder = NSApp.keyWindow?.firstResponder as? NSTextView {
                responder.insertText(text, replacementRange: responder.selectedRange())
                success = true
            }
        }
        return success
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
