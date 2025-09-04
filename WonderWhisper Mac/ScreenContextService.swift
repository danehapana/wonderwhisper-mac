import Foundation
import ApplicationServices
import AppKit
import Vision

final class ScreenContextService {
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
}
