// Thin wrapper around `AXIsProcessTrustedWithOptions` so the rest
// of the adapter (and the App) can ask one question:
// "is perch allowed to read the AX tree right now?"
//
// The system prompt that appears the FIRST time we call this with
// `prompt = true` is the only UI perch shows during onboarding. It
// links straight to System Settings → Privacy & Security →
// Accessibility, where the user has to toggle perch on.
//
// TCC keys the grant to the code-signing identity, so once the
// `setup-signing-cert.sh` flow has been run, the grant survives
// rebuilds and reinstalls of the same code-signed bundle. Ad-hoc
// signed binaries lose the grant on every rebuild — the symptom
// is `AXIsProcessTrusted()` returning `false` immediately after a
// fresh `swift build`.

import ApplicationServices
import Foundation

public enum AXTrust {

    /// `true` if the current process has Accessibility access right
    /// now. No prompt is shown.
    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// `true` if granted, otherwise display the system prompt and
    /// return `false`. Idempotent — the prompt is only shown once
    /// per granted-or-denied state.
    ///
    /// The option key is the documented string literal rather than
    /// the global `kAXTrustedCheckOptionPrompt` symbol — Swift 6
    /// strict concurrency flags references to that global as
    /// shared mutable state, while the literal compiles cleanly.
    /// The two are identical at runtime.
    @discardableResult
    public static func ensureTrusted() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
