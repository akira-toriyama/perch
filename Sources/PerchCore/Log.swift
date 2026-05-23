// Two-channel logger shared by every module. Lives in Core so both
// the Adapter and App can call it without crossing layer rules
// (same policy as stroke / facet).
//
//   Log.line(...)   always on  — operational events.
//   Log.debug(...)  gated      — enabled by `--debug` at startup.
//
// Both write to /tmp/perch.log; `--debug` also mirrors to stderr so
// foreground users see events live.

import Foundation

/// Toggled by `perch --debug` in `Main.swift`. Read by `Log.debug`.
public nonisolated(unsafe) var debugMode = false

public enum Log {
    /// Path of the on-disk log file. Public so test setup can clear
    /// it between runs.
    public static let path = "/tmp/perch.log"

    /// Always-on operational log line.
    public static func line(_ s: String) {
        write(prefix: "", s)
    }

    /// Verbose log line. No-op unless `debugMode` is `true` — costs
    /// one boolean check on the disabled path.
    public static func debug(_ s: String) {
        guard debugMode else { return }
        write(prefix: "[debug] ", s)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func write(prefix: String, _ s: String) {
        let stamp = formatter.string(from: Date())
        let line = "\(stamp) \(prefix)\(s)\n"
        if let data = line.data(using: .utf8) {
            if let h = FileHandle(forWritingAtPath: path) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                // First write: create the file.
                FileManager.default.createFile(
                    atPath: path, contents: data)
            }
            if debugMode {
                FileHandle.standardError.write(data)
            }
        }
    }
}
