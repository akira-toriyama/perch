// Raw AX tree dumper for diagnostic use (`perch --dump-ax-tree`).
//
// `--dump-ax` shows what the filter chain ACTUALLY labels.
// `--dump-ax-tree` shows the underlying RAW tree before any filter —
// every AX node depth-first, with role / frame / action support /
// child counts / a web-area marker. Essential when triaging "why
// isn't <element> visible to perch?" against shell-rendered apps
// (Chrome / Electron / WKWebView hosts):
//
//   - If a node doesn't appear in --dump-ax-tree at all, the AX
//     backend is hiding it (Chrome's lazy renderer, an Electron
//     content area that hasn't been awakened yet, …).
//   - If it appears but is missing from --dump-ax, the filter chain
//     dropped it — read the per-line annotation to see why.
//
// Kept separate from AXSource so the dump path doesn't accidentally
// inherit AXSource's filter state (window-clamp frame, dedup state,
// …) — the raw tree is the raw tree.

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import PerchCore

public enum AXDump {

    /// Cap on tree depth. 64 is deeper than the native default
    /// (`AXUIElementSource.maxDepth = 32`) so the dump shows what
    /// the walker would otherwise miss inside a web area; capped
    /// to keep a pathological DOM from spinning forever.
    public static let maxDepth = 64

    /// Walk the frontmost app's focused window depth-first and write
    /// one line per node to `out`. Does NOT touch the role allow-list
    /// or any of the filter chain — the point is to surface what AX
    /// itself sees.
    @MainActor
    public static func dumpRawTree(to out: inout some TextOutputStream) {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            print("perch: no frontmost app", to: &out)
            return
        }
        let bid = front.bundleIdentifier ?? "<no bundle id>"
        print("perch dump-ax-tree → \(bid) (pid \(front.processIdentifier))",
              to: &out)

        let app = AXUIElementCreateApplication(front.processIdentifier)

        // Mirror AXSource: wake renderer-accessibility on Chromium /
        // Electron apps before the walk, so the standalone dump
        // surfaces the same `*WEB*` subtree the daemon would see.
        // See AXSource.enumerate() for the rationale on the two
        // attributes and why Enhanced is bundle-id-gated.
        //
        // First-run latency caveat applies — Chrome populates the
        // renderer AX asynchronously. If the first dump shows no
        // `*WEB*` marker on a Chromium app, wait a second and
        // re-run.
        let wakeM = AXUIElementSetAttributeValue(
            app,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue)
        let wakeEStr: String
        if AXUIElementSource.isChromiumBundle(bid) {
            let e = AXUIElementSetAttributeValue(
                app,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanTrue)
            wakeEStr = String(e.rawValue)
        } else {
            wakeEStr = "skipped"
        }
        print("ax: wake → \(bid) "
              + "manual=\(wakeM.rawValue) enhanced=\(wakeEStr)",
              to: &out)

        guard let focused = copy(app, kAXFocusedWindowAttribute),
              CFGetTypeID(focused as CFTypeRef) == AXUIElementGetTypeID()
        else {
            print("perch: no focused window for \(bid)", to: &out)
            return
        }
        let window = focused as! AXUIElement   // checked via AXUIElementGetTypeID

        var stats = Stats()
        walk(window, depth: 0, stats: &stats, to: &out)
        print("--", to: &out)
        print("nodes: \(stats.nodes) "
              + "web-areas: \(stats.webAreas) "
              + "depth-clipped: \(stats.clipped)",
              to: &out)
    }

    private struct Stats {
        var nodes = 0
        var webAreas = 0
        var clipped = 0
    }

    private static func walk(
        _ node: AXUIElement,
        depth: Int,
        stats: inout Stats,
        to out: inout some TextOutputStream
    ) {
        if depth > maxDepth {
            stats.clipped += 1
            return
        }

        let rawRole = (copy(node, kAXRoleAttribute) as? String) ?? "?"
        let role = rawRole.hasPrefix("AX")
            ? String(rawRole.dropFirst(2)) : rawRole
        let frame = frame(node)
        let actions = actionNames(node)

        // "-" means the attribute is absent on this node; "0" means
        // present but empty. Distinguishing matters for triage:
        // Chrome's pre-wake nodes report `kAXVisibleChildren` as
        // absent (-), not empty (0).
        let kidsAttr = copy(node, kAXChildrenAttribute) as? [AXUIElement]
        let vKidsAttr = copy(node, kAXVisibleChildrenAttribute) as? [AXUIElement]
        let kidsStr = kidsAttr.map { "\($0.count)" } ?? "-"
        let vKidsStr = vKidsAttr.map { "\($0.count)" } ?? "-"

        let title = (copy(node, kAXTitleAttribute) as? String)
            ?? (copy(node, kAXValueAttribute) as? String)
            ?? ""
        let titleSnippet = title.isEmpty
            ? ""
            : " \"\(title.prefix(40))\""

        let isWeb = (role == "WebArea")
        if isWeb { stats.webAreas += 1 }

        let indent = String(repeating: "  ", count: depth)
        let frameStr = frame.map {
            String(format: "(%5d,%5d %4d×%4d)",
                   Int($0.minX), Int($0.minY),
                   Int($0.width), Int($0.height))
        } ?? "(no frame)            "
        let actionsStr = actions.isEmpty ? "·" : actions.joined(separator: ",")
        let marker = isWeb ? "  *WEB*" : ""
        print("\(indent)[d=\(depth)] \(role) \(frameStr)  "
              + "kids=\(kidsStr) vis=\(vKidsStr)  actions=[\(actionsStr)]"
              + "\(marker)\(titleSnippet)",
              to: &out)

        stats.nodes += 1

        // Same fallback rule as AXSource: use kAXVisibleChildren
        // only when it's present AND non-empty. An empty visible
        // list usually means "AX-aware container, but we choose
        // to expose nothing" — fall through to plain kAXChildren
        // rather than declare the subtree empty.
        let children: [AXUIElement]
        if let v = vKidsAttr, !v.isEmpty {
            children = v
        } else {
            children = kidsAttr ?? []
        }
        for child in children {
            walk(child, depth: depth + 1, stats: &stats, to: &out)
        }
    }

    // MARK: - AX read helpers
    //
    // Duplicated from AXSource intentionally — dump is a diagnostic
    // path, kept independent of the enumeration code so behaviour
    // changes there don't silently alter what the dump reports.

    private static func copy(_ node: AXUIElement, _ name: String) -> Any? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(node, name as CFString, &v)
        return err == .success ? v : nil
    }

    private static func frame(_ node: AXUIElement) -> CGRect? {
        guard let posAny = copy(node, kAXPositionAttribute),
              let sizeAny = copy(node, kAXSizeAttribute),
              CFGetTypeID(posAny as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeAny as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        let pos = posAny as! AXValue
        let size = sizeAny as! AXValue
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pos, .cgPoint, &p),
              AXValueGetValue(size, .cgSize, &s)
        else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func actionNames(_ node: AXUIElement) -> [String] {
        var arr: CFArray?
        let err = AXUIElementCopyActionNames(node, &arr)
        guard err == .success, let names = arr as? [String] else { return [] }
        return names.map { name in
            // Strip the AX prefix so the line stays scannable.
            name.hasPrefix("AX") ? String(name.dropFirst(2)) : name
        }
    }
}
