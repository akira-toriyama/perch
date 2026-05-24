// `UIElementSource` for real macOS apps.
//
// On every `enumerate()` call we:
//   1. Resolve the frontmost app via NSWorkspace.
//   2. Get its focused window via AXUIElement(kAXFocusedWindow).
//   3. Capture the window's frame so we can drop AX nodes whose
//      visible position is outside the window (Electron / web AX
//      trees expose a lot of off-screen content and we don't
//      want pills floating over the desktop).
//   4. Walk the AX subtree of that window, depth-first.
//   5. Keep only nodes whose role (without `AX`) is in `roles`,
//      that support `kAXPressAction` (rules out decorative
//      divs that map to a role but don't actually click), and
//      whose frame intersects the window's frame.
//   6. De-duplicate near-overlapping pills (within `proximityPx`)
//      so a tightly nested AX tree doesn't pile a wall of pills
//      on the same visible button.
//   7. Build a backend-neutral `UIElement` for each survivor;
//      store the live `AXUIElement` in a side-table keyed by the
//      same synthetic id so a later `act(id:as:)` can resolve back.
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

    /// Two elements whose top-left corners are within this many
    /// points are considered "the same visible target" for the
    /// purposes of de-duplication. AX trees from web-shell apps
    /// (Cursor, VS Code, Slack) often expose a stack of 3-5 nodes
    /// at the same place (container ➜ wrapper ➜ button); we keep
    /// the first one that supports `kAXPressAction` and drop the
    /// rest. 4pt is tight enough not to collapse genuinely
    /// adjacent toolbar buttons.
    private let proximityPx: CGFloat = 4

    /// Window frame captured at the top of each `enumerate()` for
    /// the in-bounds filter. `.zero` means "no clipping" (we
    /// couldn't read the window's frame for some reason — falls
    /// open rather than hiding everything).
    private var windowFrame: CGRect = .zero

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
        windowFrame = frameOf(window) ?? .zero

        var raw: [UIElement] = []
        walk(window, depth: 0, pid: front.processIdentifier, into: &raw)
        let pruned = dedupNearOverlaps(raw)
        if pruned.count != raw.count {
            Log.debug("ax: de-dup \(raw.count) → \(pruned.count)")
        }
        // Rebuild liveById so dropped ids don't keep stale AXUIElement
        // handles around — the dedup loop keeps the FIRST element at
        // each cluster, so we just remove the dropped ids.
        let kept = Set(pruned.map(\.id))
        for id in liveById.keys where !kept.contains(id) {
            liveById.removeValue(forKey: id)
        }
        Log.line("ax: enumerated \(pruned.count) hint(s) in \(bundleID)")
        return pruned
    }

    public func act(id: String, as action: HintAction) -> Bool {
        guard let elt = liveById[id] else {
            Log.line("dispatch: no live element for id=\(id)")
            return false
        }
        switch action {
        case .press:
            return perform(elt, action: kAXPressAction as CFString,
                           tag: "AXPress", id: id)
        case .rightClick:
            return perform(elt, action: kAXShowMenuAction as CFString,
                           tag: "AXShowMenu", id: id)
        case .focus:
            // kAXFocusedAttribute is a boolean attribute, not an
            // action — settable via AXUIElementSetAttributeValue.
            let err = AXUIElementSetAttributeValue(
                elt, kAXFocusedAttribute as CFString,
                kCFBooleanTrue)
            if err == .success {
                Log.line("dispatch: AXFocus ok → id=\(id)")
                return true
            }
            Log.line("dispatch: AXFocus failed (\(err.rawValue)) → id=\(id)")
            return false
        case .copyTitle:
            // Resolve title from the side-table'd UIElement.label
            // would require keeping it post-enumeration; cheaper
            // to re-read the live attribute at copy time.
            let title = (copyAttribute(elt, kAXTitleAttribute) as? String)
                ?? (copyAttribute(elt, kAXValueAttribute) as? String)
                ?? ""
            guard !title.isEmpty else {
                Log.line("dispatch: copyTitle empty → id=\(id)")
                return false
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(title, forType: .string)
            Log.line("dispatch: copyTitle ok (\(title.count) chars) → id=\(id)")
            return true
        }
    }

    /// Common path for the two action verbs that both go through
    /// `AXUIElementPerformAction` — folds the success / failure
    /// log into one place.
    private func perform(
        _ elt: AXUIElement, action: CFString, tag: String, id: String
    ) -> Bool {
        let err = AXUIElementPerformAction(elt, action)
        if err == .success {
            Log.line("dispatch: \(tag) ok → id=\(id)")
            return true
        }
        Log.line("dispatch: \(tag) failed (\(err.rawValue)) → id=\(id)")
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

        if roles.contains(role),
           let frame = frameOf(node),
           supportsPress(node),
           insideWindow(frame) {
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

    /// `true` when the element advertises `kAXPressAction` (or
    /// `kAXShowMenuAction` — those are the two activation paths
    /// perch can dispatch). Filters out role-bearing-but-inert
    /// elements, which are common in web-shell apps where
    /// containers report a "Button" role without supporting click.
    private func supportsPress(_ node: AXUIElement) -> Bool {
        var actions: CFArray?
        let err = AXUIElementCopyActionNames(node, &actions)
        guard err == .success,
              let names = actions as? [String]
        else {
            // Couldn't read the action list — be permissive (keep
            // the element) rather than hide a legitimate hint.
            return true
        }
        return names.contains(kAXPressAction as String)
            || names.contains(kAXShowMenuAction as String)
    }

    /// `true` when `frame` overlaps the focused window's frame.
    /// Drops elements positioned outside the visible window — the
    /// off-screen scroll tail of a large AX tree, modal-backed
    /// elements still in the tree, etc. Falls open (always true)
    /// when we couldn't read the window's frame.
    private func insideWindow(_ frame: CGRect) -> Bool {
        guard windowFrame.width > 0, windowFrame.height > 0
        else { return true }
        return windowFrame.intersects(frame)
    }

    /// Drop elements whose top-left corner is within `proximityPx`
    /// of another already-kept element's top-left. Keeps the
    /// FIRST one encountered (depth-first, ancestors before
    /// descendants), which is usually the most "container-like"
    /// match — and either container or leaf is a fine click target
    /// since they fire the same AX action.
    private func dedupNearOverlaps(_ elements: [UIElement]) -> [UIElement] {
        var kept: [UIElement] = []
        kept.reserveCapacity(elements.count)
        for e in elements {
            let p = e.frame.origin
            let collides = kept.contains { other in
                abs(other.frame.origin.x - p.x) < proximityPx
                    && abs(other.frame.origin.y - p.y) < proximityPx
            }
            if !collides { kept.append(e) }
        }
        return kept
    }
}
