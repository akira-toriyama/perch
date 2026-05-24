// Session-level CGEventTap for keyDown capture during hint mode.
//
// Why a tap and not `NSEvent.addLocalMonitorForEvents`: perch runs
// as an accessory app that *never takes focus* — taking focus would
// move the user's frontmost window out from under them, exactly the
// problem this module fixes (overlay shows, user presses a label,
// the AXPress lands while their cursor / typing context stays put).
// Local NSEvent monitors only fire for events delivered to our app,
// which they aren't when we're not active. A CGEventTap sees every
// keyDown system-wide and lets us swallow the ones we consume
// (return `nil` from the callback) so the underlying app doesn't
// receive a stray "a" / "s" while the user is resolving a label.
//
// The tap is install/uninstalled per overlay show — perch is not a
// long-lived keyboard interceptor.

import ApplicationServices
import CoreGraphics
import Foundation
import PerchCore

public final class KeyTap: @unchecked Sendable {

    /// Callback receives (`keyCode`, modifier `flags`, lowercased
    /// typed character). The character is what the user actually
    /// typed under the current keyboard layout (so "a" on QWERTY,
    /// "q" on AZERTY for the same physical position) — that's what
    /// users think in. Return `true` to swallow the event, `false`
    /// to let it through to the underlying app. Callers typically
    /// let modifier-held events through so the user can still
    /// Cmd-Q / Cmd-Tab while the overlay is up.
    fileprivate let onKeyDown: @Sendable (CGKeyCode, CGEventFlags, String) -> Bool

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init(
        onKeyDown: @escaping @Sendable (CGKeyCode, CGEventFlags, String) -> Bool
    ) {
        self.onKeyDown = onKeyDown
    }

    deinit { uninstall() }

    /// Install the tap. Returns `false` if creation failed (caller
    /// should fall back gracefully — usually a missing Accessibility
    /// grant). Idempotent: re-installing while already up is a no-op.
    @discardableResult
    public func install() -> Bool {
        guard tap == nil else { return true }

        let mask: CGEventMask
            = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                // System can disable a tap that takes too long;
                // re-enable on its own probe events. (Otherwise the
                // tap silently dies under load and the user gets a
                // stale overlay.)
                if type == .tapDisabledByTimeout
                    || type == .tapDisabledByUserInput {
                    let kt = Unmanaged<KeyTap>
                        .fromOpaque(userInfo).takeUnretainedValue()
                    if let p = kt.tap {
                        CGEvent.tapEnable(tap: p, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    let kt = Unmanaged<KeyTap>
                        .fromOpaque(userInfo).takeUnretainedValue()
                    let kc = CGKeyCode(
                        event.getIntegerValueField(.keyboardEventKeycode))
                    let flags = event.flags
                    var length = 0
                    var buf = [UniChar](repeating: 0, count: 4)
                    event.keyboardGetUnicodeString(
                        maxStringLength: 4,
                        actualStringLength: &length,
                        unicodeString: &buf)
                    let str = String(
                        utf16CodeUnits: buf, count: length).lowercased()
                    if kt.onKeyDown(kc, flags, str) {
                        return nil           // swallow
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            Log.line("keytap: tapCreate failed (missing Accessibility?)")
            return false
        }

        tap = port
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        runLoopSource = src
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    public func uninstall() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
            runLoopSource = nil
        }
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            tap = nil
        }
    }
}
