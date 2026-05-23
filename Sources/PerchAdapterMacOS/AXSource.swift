// `UIElementSource` for real macOS apps.
//
// On every `enumerate()` call we:
//   1. Resolve the frontmost app via NSWorkspace.
//   2. Get its focused window via AXUIElement(kAXFocusedWindow).
//   3. Walk the AX subtree of that window, depth-first.
//   4. Keep only nodes whose role (without `AX`) is in `roles`.
//   5. Build a backend-neutral `UIElement` for each match, store
//      the live `AXUIElement` in a side-table keyed by the same
//      synthetic id so a later `press(id:)` can resolve back.
//
// Core never sees `AXUIElement` — same policy as stroke / facet.
// The side-table is owned by this adapter and cleared at the start
// of every enumeration so we don't leak stale handles after the
// frontmost focus moves.

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import PerchCore

public final class AXUIElementSource: UIElementSource, @unchecked Sendable {

    // Roles to label, configured by `PerchConfig.roles`.
    private var roles: Set<String>

    // Bundle IDs perch refuses to label (e.g. apps with their own
    // keyboard nav). Empty in the default config.
    private var excludes: Set<String>

    // (id → live AXUIElement) — only valid for the most recent
    // enumeration. Re-cleared at the top of every `enumerate()`.
    private var liveById: [String: AXUIElement] = [:]

    // Monotonic counter so each enumerated element gets a unique
    // string id without needing to hash the opaque AXUIElement.
    // Reset at the top of every `enumerate()` along with `liveById`.
    private var nextSeq: Int = 0

    // Recursion guard. AX trees are typically a few hundred nodes
    // for a native window; we cap deep recursions so a buggy app
    // can't lock the daemon in an enumeration storm.
    private let maxDepth = 32

    public init(config: PerchConfig) {
        self.roles = Set(config.roles)
        self.excludes = Set(config.excludeApps)
    }

    public func updateConfig(_ cfg: PerchConfig) {
        self.roles = Set(cfg.roles)
        self.excludes = Set(cfg.excludeApps)
    }

    // MARK: - UIElementSource

    public func enumerate() -> [UIElement] {
        liveById.removeAll(keepingCapacity: true)
        nextSeq = 0

        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier
        else {
            Log.debug("ax: no frontmost app")
            return []
        }
        if excludes.contains(bundleID) {
            Log.debug("ax: excluded app \(bundleID)")
            return []
        }
        Log.debug("ax: front=\(bundleID) pid=\(front.processIdentifier)")

        let appElt = AXUIElementCreateApplication(front.processIdentifier)
        guard let focused = copyAttribute(appElt, kAXFocusedWindowAttribute),
              CFGetTypeID(focused as CFTypeRef) == AXUIElementGetTypeID()
        else {
            Log.debug("ax: no focused window for \(bundleID)")
            return []
        }
        let window = focused as! AXUIElement   // checked via AXUIElementGetTypeID

        var out: [UIElement] = []
        walk(window, depth: 0, pid: front.processIdentifier, into: &out)
        Log.line("ax: enumerated \(out.count) hint(s) in \(bundleID)")
        return out
    }

    public func press(id: String) -> Bool {
        guard let elt = liveById[id] else {
            Log.line("dispatch: no live element for id=\(id)")
            return false
        }
        let err = AXUIElementPerformAction(elt, kAXPressAction as CFString)
        if err == .success {
            Log.line("dispatch: AXPress ok → id=\(id)")
            return true
        }
        Log.line("dispatch: AXPress failed (\(err.rawValue)) → id=\(id)")
        return false
    }

    // MARK: - Internals

    private func walk(
        _ node: AXUIElement,
        depth: Int,
        pid: pid_t,
        into out: inout [UIElement]
    ) {
        if depth > maxDepth { return }

        // Role check — keep it cheap, before reading frame / title.
        let rawRole = (copyAttribute(node, kAXRoleAttribute) as? String) ?? ""
        let role = rawRole.hasPrefix("AX")
            ? String(rawRole.dropFirst(2)) : rawRole

        if roles.contains(role), let frame = frameOf(node) {
            let title = (copyAttribute(node, kAXTitleAttribute) as? String)
                ?? (copyAttribute(node, kAXValueAttribute) as? String)
                ?? ""
            nextSeq += 1
            let id = "\(pid):\(nextSeq)"
            liveById[id] = node
            out.append(UIElement(
                id: id, role: role, label: title, frame: frame))
        }

        // Recurse: walk visible children if any. `kAXChildren` is
        // the universal recursion edge — every container exposes it.
        if let children
            = copyAttribute(node, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                walk(child, depth: depth + 1, pid: pid, into: &out)
            }
        }
    }

    /// Position + size of an AX node, in screen coordinates (top-left
    /// origin to match Cocoa's screen rect convention used by the
    /// overlay panel).
    private func frameOf(_ node: AXUIElement) -> CGRect? {
        guard let posAny = copyAttribute(node, kAXPositionAttribute),
              let sizeAny = copyAttribute(node, kAXSizeAttribute),
              CFGetTypeID(posAny as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeAny as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        let pos = posAny as! AXValue       // checked via AXValueGetTypeID
        let size = sizeAny as! AXValue
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pos, .cgPoint, &p),
              AXValueGetValue(size, .cgSize, &s)
        else { return nil }
        if s.width < 6 || s.height < 6 { return nil }   // skip dots
        return CGRect(origin: p, size: s)
    }

    /// Wrapper around `AXUIElementCopyAttributeValue` that returns
    /// the value as a Swift `Any?` for ergonomics.
    private func copyAttribute(
        _ node: AXUIElement, _ name: String
    ) -> Any? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            node, name as CFString, &value)
        guard err == .success else { return nil }
        return value
    }
}
