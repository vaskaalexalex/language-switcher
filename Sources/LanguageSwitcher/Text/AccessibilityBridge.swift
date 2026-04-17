import AppKit
import ApplicationServices

enum AccessibilityBridge {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard err == .success, let element = value else { return nil }
        return (element as! AXUIElement)
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    static func rangeAttribute(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success, let axValue = value else { return nil }
        var range = CFRange(location: 0, length: 0)
        if AXValueGetValue(axValue as! AXValue, .cfRange, &range) {
            return range
        }
        return nil
    }

    static func setStringAttribute(_ element: AXUIElement, _ attribute: String, _ value: String) -> Bool {
        let err = AXUIElementSetAttributeValue(element, attribute as CFString, value as CFString)
        return err == .success
    }

    static func setRangeAttribute(_ element: AXUIElement, _ attribute: String, _ range: CFRange) -> Bool {
        var r = range
        guard let axValue = AXValueCreate(.cfRange, &r) else { return false }
        let err = AXUIElementSetAttributeValue(element, attribute as CFString, axValue)
        return err == .success
    }

    static func isSecureField(_ element: AXUIElement) -> Bool {
        if let subrole = stringAttribute(element, kAXSubroleAttribute) {
            return subrole == (kAXSecureTextFieldSubrole as String)
        }
        return false
    }
}
