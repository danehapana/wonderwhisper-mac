import Foundation
import ApplicationServices
import AppKit
import Vision

final class ScreenContextService {
    struct FieldContext {
        let before: String
        let selection: String
        let after: String
        let insertionLocation: Int
    }
    func frontmostAppNameAndBundle() -> (name: String?, bundleId: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, app?.bundleIdentifier)
    }

    func focusedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        var value: AnyObject?
        let err2 = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value)
        if err2 == .success, let str = value as? String { return str }
        return nil
    }

    func selectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        var sel: AnyObject?
        let res = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel)
        if res == .success, let s = sel as? String, !s.isEmpty { return s }
        return nil
    }

    func captureActiveWindowText() async -> String? {
        let svc = ScreenCaptureService()
        return await svc.captureActiveWindowText()
    }

    // Returns a small window of text around the caret/selection in the focused field when available via AX
    // Limits to ~120 chars before and after to keep prompts light
    func currentFieldContext(maxContext: Int = 120) -> FieldContext? {
        let sys = AXUIElementCreateSystemWide()
        var focusedObj: AnyObject?
        let err = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedObj)
        guard err == .success, let elementObj = focusedObj else { return nil }
        let element = elementObj as! AXUIElement

        // Entire field value
        var valueObj: AnyObject?
        let vErr = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueObj)
        guard vErr == .success, let fullText = valueObj as? String else { return nil }

        // Selected range (or caret position if length == 0)
        var rangeObj: AnyObject?
        let rErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeObj)
        var location: Int = 0
        var length: Int = 0
        if rErr == .success, let axVal = rangeObj {
            if CFGetTypeID(axVal) == AXValueGetTypeID() {
                let val = axVal as! AXValue
                var cfRange = CFRange(location: 0, length: 0)
                if AXValueGetValue(val, .cfRange, &cfRange) {
                    location = cfRange.location
                    length = cfRange.length
                }
            }
        }
        if location < 0 { location = 0 }
        if location > fullText.count { location = fullText.count }
        if length < 0 { length = 0 }
        if location + length > fullText.count { length = max(0, fullText.count - location) }

        let startIdx = fullText.startIndex
        let locIdx = fullText.index(startIdx, offsetBy: location)
        let selEndIdx = fullText.index(locIdx, offsetBy: length, limitedBy: fullText.endIndex) ?? fullText.endIndex
        let beforeFull = String(fullText[..<locIdx])
        let selection = String(fullText[locIdx..<selEndIdx])
        let afterFull = String(fullText[selEndIdx...])

        let before = String(beforeFull.suffix(maxContext))
        let after = String(afterFull.prefix(maxContext))
        return FieldContext(before: before, selection: selection, after: after, insertionLocation: location)
    }
}
