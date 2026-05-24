// Global hotkey via Carbon's `RegisterEventHotKey`. There's no
// modern AppKit replacement; every macOS keyboard launcher
// (Raycast, Alfred, Hammerspoon) uses this same API. It works
// system-wide once the binary has been granted Accessibility.
//
// The hotkey set here is the activation trigger for hint mode —
// perch is otherwise dormant. A second registration (cancelHotkey,
// hard-coded to `Esc` while hint mode is up) is handled by the
// overlay's local key monitor rather than here.

import AppKit
import Carbon.HIToolbox
import Foundation
import PerchCore

public final class HotkeyMonitor: @unchecked Sendable {

    /// Hot-key identifiers are arbitrary uint32s; pick a constant
    /// that doesn't collide with any system one (no central
    /// registry — we just need it unique within our own process).
    private static let signature: OSType = 0x50524348      // 'PRCH'
    private static let activateID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate let callback: @Sendable () -> Void

    /// `callback` fires on the main thread every time the
    /// configured combo is pressed (key-down only). Re-installing
    /// safely replaces the previous registration.
    public init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    deinit { uninstall() }

    /// Install / replace the active hotkey. Throws away the
    /// previous registration if any.
    public func install(combo: HotkeyCombo) {
        uninstall()

        // Translate combo → Carbon (keyCode, modifierFlags).
        guard let keyCode = Self.keyCode(for: combo.key) else {
            Log.line("hotkey: unknown key \"\(combo.key)\" — not bound")
            return
        }
        var carbonMods: UInt32 = 0
        if combo.modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        if combo.modifiers.contains(.ctrl)  { carbonMods |= UInt32(controlKey) }
        if combo.modifiers.contains(.alt)   { carbonMods |= UInt32(optionKey) }
        if combo.modifiers.contains(.cmd)   { carbonMods |= UInt32(cmdKey) }

        // Install the C event handler once per monitor instance.
        // The trampoline pulls our `self` out of the userData
        // pointer so we can call back into Swift.
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userInfo in
                guard let userInfo = userInfo, let eventRef = eventRef
                else { return noErr }
                let mon = Unmanaged<HotkeyMonitor>
                    .fromOpaque(userInfo).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                if hkID.id == HotkeyMonitor.activateID {
                    // Lift the @Sendable callback out of `mon` and
                    // hop to main explicitly — Carbon dispatches the
                    // handler on the main thread, but Swift 6's
                    // strict checker can't see that.
                    let cb = mon.callback
                    DispatchQueue.main.async { cb() }
                }
                return noErr
            },
            1, &spec, userInfo, &handlerRef)

        let id = EventHotKeyID(signature: Self.signature, id: Self.activateID)
        var newRef: EventHotKeyRef?
        let err = RegisterEventHotKey(
            UInt32(keyCode), carbonMods, id,
            GetApplicationEventTarget(), 0, &newRef)
        if err == noErr {
            ref = newRef
            Log.line("hotkey: bound \(human(combo))")
        } else {
            Log.line("hotkey: RegisterEventHotKey failed err=\(err) for \(human(combo))")
        }
    }

    public func uninstall() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }

    // MARK: - Key name → keycode

    /// Translate a config-style key name (`"space"`, `"esc"`,
    /// `"a"` …) to a Carbon virtual keycode. Returns `nil` for
    /// unknown names. Public because `OverlayWindow` needs the
    /// same mapping to resolve `[hotkey].cancel`; centralising
    /// it here keeps the canonical list in one place.
    public static func keyCode(for key: String) -> Int? {
        switch key {
        case "space":  return kVK_Space
        case "return", "enter": return kVK_Return
        case "esc", "escape": return kVK_Escape
        case "tab":    return kVK_Tab
        case "delete", "backspace": return kVK_Delete
        case "f1":  return kVK_F1
        case "f2":  return kVK_F2
        case "f3":  return kVK_F3
        case "f4":  return kVK_F4
        case "f5":  return kVK_F5
        case "f6":  return kVK_F6
        case "f7":  return kVK_F7
        case "f8":  return kVK_F8
        case "f9":  return kVK_F9
        case "f10": return kVK_F10
        case "f11": return kVK_F11
        case "f12": return kVK_F12
        case "a": return kVK_ANSI_A
        case "b": return kVK_ANSI_B
        case "c": return kVK_ANSI_C
        case "d": return kVK_ANSI_D
        case "e": return kVK_ANSI_E
        case "f": return kVK_ANSI_F
        case "g": return kVK_ANSI_G
        case "h": return kVK_ANSI_H
        case "i": return kVK_ANSI_I
        case "j": return kVK_ANSI_J
        case "k": return kVK_ANSI_K
        case "l": return kVK_ANSI_L
        case "m": return kVK_ANSI_M
        case "n": return kVK_ANSI_N
        case "o": return kVK_ANSI_O
        case "p": return kVK_ANSI_P
        case "q": return kVK_ANSI_Q
        case "r": return kVK_ANSI_R
        case "s": return kVK_ANSI_S
        case "t": return kVK_ANSI_T
        case "u": return kVK_ANSI_U
        case "v": return kVK_ANSI_V
        case "w": return kVK_ANSI_W
        case "x": return kVK_ANSI_X
        case "y": return kVK_ANSI_Y
        case "z": return kVK_ANSI_Z
        default: return nil
        }
    }

    private func human(_ combo: HotkeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers.contains(.ctrl)  { parts.append("ctrl") }
        if combo.modifiers.contains(.alt)   { parts.append("alt") }
        if combo.modifiers.contains(.shift) { parts.append("shift") }
        if combo.modifiers.contains(.cmd)   { parts.append("cmd") }
        parts.append(combo.key)
        return parts.joined(separator: "+")
    }
}
