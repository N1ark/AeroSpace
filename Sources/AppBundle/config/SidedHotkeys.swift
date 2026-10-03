import AppKit
import Common
import HotKey

// Carbon hotkeys (that HotKey uses) can't distinguish left and right modifiers.
// Sided bindings (e.g. lalt-h) are handled by the event tap that consumes only matching key events, and lets the rest
// go through (e.g. ralt-h is still available for typing special characters).
// Unlike Carbon hotkeys, the event tap doesn't receive key events when Secure Input is enabled.
@MainActor private var sidedBindings: [HotkeyBinding] = []
@MainActor private var sidedHotkeysTap: CFMachPort? = nil
@MainActor private var consumedKeyDowns: Set<Int64> = []

@MainActor func syncSidedHotkeys(_ bindings: [HotkeyBinding]) {
    // More specific bindings win. lalt-h wins over alt-h
    sidedBindings = bindings.sorted { $0.sidedModifiers.rawValue.nonzeroBitCount > $1.sidedModifiers.rawValue.nonzeroBitCount }
    if bindings.isEmpty {
        if let sidedHotkeysTap { CGEvent.tapEnable(tap: sidedHotkeysTap, enable: false) }
        return
    }
    if sidedHotkeysTap == nil {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = unsafe CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in unsafe sidedHotkeysTapCallback(type, event) },
            userInfo: nil,
        ) else {
            reportSidedHotkeysTapFailure(bindings)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        sidedHotkeysTap = tap
    }
    if let sidedHotkeysTap { CGEvent.tapEnable(tap: sidedHotkeysTap, enable: true) }
}

@MainActor private func reportSidedHotkeysTapFailure(_ bindings: [HotkeyBinding]) {
    let msg = """
        Failed to create the keyboard event tap. The following bindings won't work:
        \(bindings.map(\.descriptionWithKeyNotation).sorted().joined(separator: ", "))
        Bindings with left/right side specific modifiers (lalt, ralt, etc.) require the event tap.
        Try re-granting the Accessibility permission to AeroSpace and restarting it.
        """
    eprint(msg)
    let prev = MessageModel.shared.message
    if prev?.body.contains(msg) != true {
        MessageModel.shared.message = Message(
            body: [prev?.body, msg].compactMap { $0 }.joined(separator: "\n\n"),
            containsWarnings: prev?.containsWarnings ?? false,
        )
    }
}

private func sidedHotkeysTapCallback(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let consume = MainActor.assumeIsolated { handleSidedHotkeysTapEvent(type, keyCode, flags, isAutorepeat) }
    return consume ? nil : unsafe Unmanaged.passUnretained(event)
}

@MainActor private func handleSidedHotkeysTapEvent(_ type: CGEventType, _ keyCode: Int64, _ flags: CGEventFlags, _ isAutorepeat: Bool) -> Bool {
    switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let sidedHotkeysTap, !sidedBindings.isEmpty { CGEvent.tapEnable(tap: sidedHotkeysTap, enable: true) }
            return false
        case .keyDown:
            guard let binding = sidedBindings.first(where: { Int64($0.keyCode.carbonKeyCode) == keyCode && $0.matches(flags) }) else {
                // The tap might have missed the keyUp of the previously consumed keyDown (e.g. the tap was disabled
                // because the binding switched to a mode without sided bindings). Don't swallow the keyUp of this keyDown
                consumedKeyDowns.remove(keyCode)
                return false
            }
            consumedKeyDowns.insert(keyCode)
            // Like Carbon, hotkeys don't trigger on autorepeat.
            if !isAutorepeat {
                onHotkeyTriggered(binding)
            }
            return true
        case .keyUp:
            return consumedKeyDowns.remove(keyCode) != nil
        default:
            return false
    }
}

extension HotkeyBinding {
    func matches(_ flags: CGEventFlags) -> Bool {
        let pressed = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)).intersection([.option, .control, .command, .shift])
        guard pressed == modifiers else { return false }
        let pressedSided = SidedModifiers(rawValue: flags.rawValue)
        return modifierKinds.allSatisfy { kind in
            let bothSides: SidedModifiers = [kind.left, kind.right]
            let expected = sidedModifiers.intersection(bothSides)
            return expected.isEmpty || pressedSided.intersection(bothSides) == expected
        }
    }
}
