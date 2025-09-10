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
        // Fallback: write to pasteboard (optionally as rich text) + Command-V with clipboard restore
        let snapshot = snapshotPasteboard()
        let pb = NSPasteboard.general
        pb.clearContents()

        // Prefer rich text (HTML/RTF) if enabled; always include plain text as a fallback
        let preferFormatted = UserDefaults.standard.bool(forKey: "insertion.pasteFormatted")
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if preferFormatted {
            if let htmlData = buildHTMLData(from: text) {
                // public.html
                item.setData(htmlData, forType: .html)
                // Some apps (Electron/web) explicitly look for text/html
                item.setData(htmlData, forType: NSPasteboard.PasteboardType("text/html"))
            }
            if let rtfData = buildRTFData(from: text) {
                item.setData(rtfData, forType: .rtf)
            }
        }
        pb.writeObjects([item])

        let ourChange = pb.changeCount
        AppLog.insertion.log("Fallback paste + Cmd+V (with clipboard restore)")
        synthesizeCmdV()
        let delay: TimeInterval = 0.45
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

    // MARK: - Formatting helpers
    private func buildHTMLData(from text: String) -> Data? {
        // Convert double newlines to paragraphs, single newlines to <br>
        func htmlEscape(_ s: String) -> String {
            var out = s
            out = out.replacingOccurrences(of: "&", with: "&amp;")
            out = out.replacingOccurrences(of: "<", with: "&lt;")
            out = out.replacingOccurrences(of: ">", with: "&gt;")
            return out
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Split paragraphs on 2+ consecutive newlines
        let normalized = trimmed.replacingOccurrences(of: "\r", with: "")
        let paraDelimiter = "\u{0001}"
        let collapsed = normalized.replacingOccurrences(of: "\\n{2,}", with: paraDelimiter, options: .regularExpression)
        let paras = collapsed.components(separatedBy: paraDelimiter)
        let body = paras.map { p in
            let esc = htmlEscape(p)
            let withBR = esc.replacingOccurrences(of: "\n", with: "<br>")
            return "<p>\(withBR)</p>"
        }.joined()
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset=\"utf-8\">
          <style>body{white-space:pre-wrap;} p{margin:0 0 12px 0;}</style>
        </head>
        <body>\(body)</body>
        </html>
        """
        return html.data(using: String.Encoding.utf8)
    }

    private func buildRTFData(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8 // points after each paragraph
        let attr = NSAttributedString(string: trimmed, attributes: [.paragraphStyle: style])
        return try? attr.data(from: NSRange(location: 0, length: attr.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
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
