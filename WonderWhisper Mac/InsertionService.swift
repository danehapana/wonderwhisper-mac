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
        // Fallback: pasteboard + Command-V with clipboard restore
        let snapshot = snapshotPasteboard()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount
        AppLog.insertion.log("Fallback paste + Cmd+V (with clipboard restore)")
        synthesizeCmdV()
        let delay: TimeInterval = 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restorePasteboard(snapshot, ifChangeCountEquals: ourChange)
        }
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

    // MARK: - Clipboard snapshot/restore
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func snapshotPasteboard() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        let items: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types {
                if let d = item.data(forType: t) { dict[t] = d }
            }
            return dict
        }
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot, ifChangeCountEquals changeCount: Int) {
        let pb = NSPasteboard.general
        // Do not clobber user clipboard if they copied something else since
        guard pb.changeCount == changeCount else { return }
        pb.clearContents()
        let newItems: [NSPasteboardItem] = snapshot.items.map { mapping in
            let item = NSPasteboardItem()
            for (type, data) in mapping { item.setData(data, forType: type) }
            return item
        }
        if !newItems.isEmpty {
            pb.writeObjects(newItems as [NSPasteboardWriting])
        }
        AppLog.insertion.log("Clipboard restored after paste")
    }
}
