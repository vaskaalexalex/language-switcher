import AppKit
import CoreGraphics

enum KeyboardSynth {
    // Carbon virtual key codes
    static let kVK_LeftArrow: CGKeyCode = 0x7B
    static let kVK_RightArrow: CGKeyCode = 0x7C
    static let kVK_ANSI_V: CGKeyCode = 0x09
    static let kVK_ANSI_C: CGKeyCode = 0x08
    static let kVK_Delete: CGKeyCode = 0x33

    /// Post a key chord. `flags` describes the modifiers to apply for the main key.
    /// We post a synthetic event with those flags set; `.cghidEventTap` delivers it
    /// low in the stack so every app sees it consistently.
    static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)

        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return }

        down.flags = flags
        up.flags = flags

        down.post(tap: .cghidEventTap)
        // Small gap so the app processes the keydown before the keyup.
        usleep(1_500)
        up.post(tap: .cghidEventTap)
    }

    static func selectPreviousWord() {
        postKey(kVK_LeftArrow, flags: [.maskAlternate, .maskShift])
    }

    /// Extend the selection by one character to the left (⇧←).
    static func extendSelectionLeftChar() {
        postKey(kVK_LeftArrow, flags: [.maskShift])
    }

    /// Shrink the selection by one character from the left edge (⇧→).
    static func shrinkSelectionRightChar() {
        postKey(kVK_RightArrow, flags: [.maskShift])
    }

    static func paste() {
        postKey(kVK_ANSI_V, flags: [.maskCommand])
    }

    static func copy() {
        postKey(kVK_ANSI_C, flags: [.maskCommand])
    }
}
