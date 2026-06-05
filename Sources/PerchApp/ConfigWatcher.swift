// Filesystem watcher for `~/.config/perch/config.toml`. Calls
// `onChange()` when the file changes so the Controller can hot-reload
// the daemon without a `perch --reload` round trip.
//
// Uses `DispatchSourceFileSystemObject` (kqueue under the hood) —
// same primitive AppKit uses internally. Doesn't poll, doesn't burn
// CPU when the file is idle.
//
// Editor write-via-rename handling: a `vim` / `code` save typically
// renames the new content over the original inode, which fires a
// `.delete` event on our open file descriptor rather than `.write`.
// We re-open the descriptor on `.delete` so subsequent edits keep
// firing — without this, the watcher would stop working after the
// first editor save and only `:w!`-style in-place writes would
// reload.
//
// Debouncing: most editors save in two syscalls (truncate + write,
// or write + atomic-rename), so we coalesce events within a 150ms
// window into a single `onChange()`. Without this we'd reload twice
// per save and the second reload would happen while the first is
// still consuming the file — same FD churn problem but at the
// Controller / overlay layer.

import Foundation
import PerchCore

@MainActor
final class ConfigWatcher {

    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    /// Debounce window — editor "save" often hits the file twice in
    /// quick succession (truncate → write, or write → rename). 150ms
    /// is short enough that the user perceives reload as immediate
    /// but long enough to coalesce both events into one reload.
    private static let debounceMs: Int = 150

    init(path: String = PerchConfig.path, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    /// Start watching. Returns `false` if the file doesn't exist yet
    /// — Controller logs that and continues without reload-on-save.
    /// Editing the file later won't auto-create the watcher (kept
    /// minimal — `perch --reload` still works as the explicit path).
    @discardableResult
    func start() -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            Log.line("config-watcher: \(path) not found — "
                     + "hot-reload disabled (run `perch --reload` manually)")
            return false
        }
        return install()
    }

    func stop() {
        source?.cancel()
        source = nil
        debounceWork?.cancel()
        debounceWork = nil
    }

    private func install() -> Bool {
        let fd = open(path, O_EVTONLY)
        if fd < 0 {
            Log.line("config-watcher: open() failed errno=\(errno)")
            return false
        }
        // Watch for content changes (`.write`, `.extend`) AND for
        // the editor's atomic-rename pattern (`.delete` /
        // `.rename` on our held fd). The latter is what most
        // editors actually do — without it the watcher would stop
        // firing after the first save.
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // .delete / .rename means our held fd points at a now-
            // unlinked inode (editor wrote the new content into a
            // sibling path and renamed it over ours). Cancel and
            // re-install so the watcher keeps following the *path*
            // rather than the original inode.
            let data = src.data
            let needsReopen = data.contains(.delete) || data.contains(.rename)
            self.scheduleReload()
            if needsReopen {
                src.cancel()
                // Defer the re-install one runloop turn so the
                // editor's rename completes before we open() the
                // new file at the same path.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    MainActor.assumeIsolated { _ = self.install() }
                }
            }
        }
        src.setCancelHandler {
            close(fd)
        }
        src.resume()
        source = src
        Log.line("config-watcher: watching \(path)")
        return true
    }

    /// Coalesce a burst of FS events into a single `onChange()` call.
    /// Cancels any previously-pending invocation so the debounce
    /// window restarts on each new event.
    private func scheduleReload() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.debounceMs),
            execute: work)
    }
}
