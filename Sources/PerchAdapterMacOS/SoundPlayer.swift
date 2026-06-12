// Audio feedback for hint mode — plays a short sound on activate /
// match / unmatch. Config takes either a macOS system-sound name
// (`"Tink"` / `"Pop"` / `"Glass"` / `"Hero"` / ...) or a file path
// (`"~/foo.mp3"` / `"/Users/me/click.wav"`), so the user can drop
// in any audio file the AVFoundation pipeline accepts (mp3 / m4a /
// wav / aiff).
//
// `NSSound` is the path of least resistance here — it's been the
// AppKit go-to since 10.5, handles both system sounds and file
// playback, and lets us pre-load + reuse the same instance so
// repeated plays are zero-latency. The trade-off is no playback
// callbacks; we just fire-and-forget.

import AppKit
import Foundation
import PerchCore

@MainActor
public final class SoundPlayer {

    /// Pre-loaded sounds keyed by direction. nil means the user
    /// disabled that direction (empty `""`) OR the spec
    /// failed to resolve — the play methods are safe to call in
    /// either case (no-op).
    private var match: NSSound?
    private var unmatch: NSSound?
    private var activate: NSSound?
    private var volume: Float = 0.5

    public init(config: PerchConfig) {
        updateConfig(config)
    }

    /// Re-resolve every sound from the current config. Called on
    /// `Controller.reload` so a fresh `match-sound = "~/new.mp3"`
    /// takes effect at the next hint resolve.
    public func updateConfig(_ cfg: PerchConfig) {
        match = Self.load(cfg.sound.match, role: "match")
        unmatch = Self.load(cfg.sound.unmatch, role: "unmatch")
        activate = Self.load(cfg.sound.activate, role: "activate")
        volume = max(0, min(1, Float(cfg.sound.volume)))
        match?.volume = volume
        unmatch?.volume = volume
        activate?.volume = volume
    }

    public func playMatch()    { fire(match) }
    public func playUnmatch()  { fire(unmatch) }
    public func playActivate() { fire(activate) }

    /// `NSSound.play()` is no-op when the sound is already
    /// mid-playback; calling `.stop()` first lets rapid-fire
    /// resolves all produce a fresh click rather than swallowing
    /// each other.
    private func fire(_ s: NSSound?) {
        guard let s else { return }
        s.stop()
        s.play()
    }

    /// Resolve a config spec into a loaded `NSSound` (or nil). Try
    /// the path interpretation first (tilde-expanded) so a file at
    /// `~/Pop.mp3` wins over a same-named system sound. Falls back
    /// to `NSSound(named:)` for vanilla `"Tink"` / `"Pop"` etc.
    /// Empty (`""`) returns nil silently — the family sentinel for
    /// "inherit / disabled" on path/name string keys.
    private static func load(_ spec: String, role: String) -> NSSound? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }

        // File path interpretation. Tilde-expand and check FS.
        let expanded = (s as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"),
           FileManager.default.fileExists(atPath: expanded) {
            if let snd = NSSound(contentsOfFile: expanded, byReference: true) {
                Log.line("sound: loaded \(role) ← \(expanded)")
                return snd
            }
            Log.line("sound: \(role) file at \(expanded) failed to load — silenced")
            return nil
        }

        // System sound name (NSSound(named:) resolves names from
        // `/System/Library/Sounds/<Name>.aiff` — the same list
        // shown in System Settings → Sound → Sound Effects).
        if let named = NSSound(named: NSSound.Name(s)) {
            Log.line("sound: loaded \(role) ← system \"\(s)\"")
            return named
        }

        Log.line("sound: \(role) unresolved \"\(s)\" — silenced")
        return nil
    }
}
