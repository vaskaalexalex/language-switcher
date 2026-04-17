import AppKit
import CoreGraphics

enum HotkeyMonitorError: Error {
    case tapCreationFailed
}

final class HotkeyMonitor {
    private static let kVK_Option: Int64 = 58
    private static let kVK_RightOption: Int64 = 61

    private static let tapWindow: TimeInterval = 0.4

    private let onTap: () -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var armed: Bool = false
    private var contaminated: Bool = false
    private var downAt: TimeInterval = 0
    private var lastKeyCode: Int64 = -1

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    func start() throws {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            throw HotkeyMonitorError.tapCreationFailed
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("HotkeyMonitor started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            if armed { contaminated = true }
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let optionDown = flags.contains(.maskAlternate)
        let onlyOptionModifier = isOnlyOption(flags)

        let isOptionKey = (keyCode == Self.kVK_Option || keyCode == Self.kVK_RightOption)

        if isOptionKey {
            if optionDown {
                armed = true
                contaminated = false
                downAt = CACurrentMediaTime()
                lastKeyCode = keyCode
                if !onlyOptionModifier {
                    contaminated = true
                }
            } else {
                let elapsed = CACurrentMediaTime() - downAt
                let shouldFire = armed && !contaminated && elapsed < Self.tapWindow
                Log.info("Option up: armed=\(armed) contaminated=\(contaminated) elapsed=\(String(format: "%.3f", elapsed)) fire=\(shouldFire)")
                armed = false
                contaminated = false
                if shouldFire {
                    DispatchQueue.main.async { [weak self] in
                        self?.onTap()
                    }
                }
            }
        } else {
            if armed { contaminated = true }
        }
    }

    private func isOnlyOption(_ flags: CGEventFlags) -> Bool {
        let disallowed: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskSecondaryFn]
        if flags.intersection(disallowed).rawValue != 0 { return false }
        return true
    }
}
