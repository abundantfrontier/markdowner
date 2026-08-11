import AppKit
import CoreGraphics
import SwiftUI

/// Single chokepoint for “new workspace window” (menu, Dock, ClingBar URL).
/// At most one `openWindow` call per click — even if URL, menu, and notifications all fire.
@MainActor
enum WorkspaceWindowBridge {
    static let workspaceWindowID = "workspace"

    static var openWindowAction: OpenWindowAction?

    private static let coalesceInterval: TimeInterval = 1.25
    private static var lastOpenAttemptDate: Date = .distantPast
    private static var isOpening = false
    private static var openFulfillmentToken: UInt64 = 0
    private static var fulfilledToken: UInt64 = 0

    /// Last workspace we ordered front while cycling (windowNumber).
    private static var lastCycledWindowNumber: Int?

    static func hasUsableWorkspaceWindow() -> Bool {
        NSApp.windows.contains { window in
            guard window.level == .normal else { return false }
            if window.isMiniaturized { return true }
            guard window.isVisible else { return false }
            return window.canBecomeKey || window.canBecomeMain
        }
    }

    /// Count of large normal workspace windows (best-effort).
    static func workspaceWindowCount() -> Int {
        NSApp.windows.filter { isWorkspaceWindow($0) }.count
    }

    /// Whether this looks like a real workspace (not Settings / sheets / tiny shells).
    static func isWorkspaceWindow(_ window: NSWindow) -> Bool {
        guard window.level == .normal, window.isVisible || window.isMiniaturized else { return false }
        let s = window.frame.size
        return s.width >= 600 && s.height >= 400
    }

    static func openNewWorkspaceWindow(activate: Bool = false) {
        let now = Date()
        if isOpening || now.timeIntervalSince(lastOpenAttemptDate) < coalesceInterval {
            NSLog(
                "Markdowner: New Window coalesced (isOpening=%@, dt=%.0fms)",
                isOpening ? "yes" : "no",
                now.timeIntervalSince(lastOpenAttemptDate) * 1000
            )
            if activate { activateApp() }
            return
        }

        isOpening = true
        lastOpenAttemptDate = now
        openFulfillmentToken &+= 1
        let token = openFulfillmentToken

        // Clear the opening gate after the debounce window.
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval) {
            isOpening = false
        }

        if let openWindowAction {
            fulfill(token: token, using: openWindowAction, activate: activate, source: "action")
            return
        }

        NotificationCenter.default.post(
            name: .markdownerOpenNewWindow,
            object: nil,
            userInfo: ["token": token, "activate": activate]
        )
        NSLog("Markdowner: New Window notification token=%llu", token)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard fulfilledToken != token else { return }
            if let openWindowAction {
                fulfill(token: token, using: openWindowAction, activate: activate, source: "retry")
            } else if activate {
                activateApp()
            }
        }
    }

    static func fulfillFromEnvironment(
        _ openWindow: OpenWindowAction,
        token: UInt64?,
        activate: Bool
    ) {
        openWindowAction = openWindow
        let token = token ?? openFulfillmentToken
        fulfill(token: token, using: openWindow, activate: activate, source: "environment")
    }

    private static func fulfill(
        token: UInt64,
        using openWindow: OpenWindowAction,
        activate: Bool,
        source: String
    ) {
        guard fulfilledToken != token else {
            NSLog("Markdowner: New Window skip duplicate fulfill token=%llu source=%@", token, source)
            return
        }
        fulfilledToken = token
        let before = workspaceWindowCount()
        openWindow(id: workspaceWindowID)
        // SwiftUI can still restore/extra-create; collapse after a tick if we spiked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let after = Self.workspaceWindowCount()
            NSLog(
                "Markdowner: New Window fulfill token=%llu source=%@ windows %d→%d",
                token, source, before, after
            )
            // If a single open produced two windows, close the newest extras keeping key.
            if after > before + 1 {
                let workspaces = NSApp.windows.filter { window in
                    guard window.level == .normal, window.isVisible || window.isMiniaturized else { return false }
                    let s = window.frame.size
                    return s.width >= 600 && s.height >= 400
                }
                // Keep the first `before + 1` in z-order (front is usually the new one we want + old ones).
                // Simpler: keep key/main + oldest windows totaling before+1
                let keepCount = before + 1
                if workspaces.count > keepCount {
                    let keep = Set(workspaces.prefix(keepCount).map { ObjectIdentifier($0) })
                    for window in workspaces where !keep.contains(ObjectIdentifier(window)) {
                        // Prefer closing non-key extras
                        if !window.isKeyWindow {
                            window.isRestorable = false
                            window.close()
                        }
                    }
                }
            }
        }
        if activate { activateApp() }
    }

    @discardableResult
    static func handleURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "markdowner" else { return false }

        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let absolute = url.absoluteString.lowercased()

        let isNewWindow =
            host == "new-window"
            || path == "new-window"
            || absolute.contains("://new-window")
            || (host == "window" && path == "new")

        if isNewWindow {
            NSLog("Markdowner: handleURL new-window")
            openNewWorkspaceWindow(activate: false)
            return true
        }

        // ClingBar / scripts: focus or cycle a workspace already on *this* Space.
        // (AX raise is unreliable for SwiftUI WindowGroup; this is the supported path.)
        // ClingBar picks focus vs cycle *before* `open` activates us (activation races isActive).
        let isFocusOnly =
            host == "focus"
            || path == "focus"
            || absolute.contains("://focus")

        let isCycle =
            host == "next-window"
            || host == "cycle-window"
            || path == "next-window"
            || path == "cycle-window"
            || absolute.contains("://next-window")
            || absolute.contains("://cycle-window")

        if isFocusOnly {
            NSLog("Markdowner: handleURL focus (on-Space)")
            focusOrCycleWorkspaceOnCurrentSpace(forceCycle: false)
            return true
        }
        if isCycle {
            NSLog("Markdowner: handleURL next-window (on-Space cycle)")
            focusOrCycleWorkspaceOnCurrentSpace(forceCycle: true)
            return true
        }
        return false
    }

    // MARK: - Space-local cycle (ClingBar)

    /// Focus the topmost on-Space workspace (`forceCycle == false`), or advance to the next one.
    /// Only considers windows currently on-screen (same Space) so we never pull windows from elsewhere.
    static func focusOrCycleWorkspaceOnCurrentSpace(forceCycle: Bool) {
        let onscreen = workspaceWindowsOnCurrentSpace()
        if onscreen.isEmpty {
            NSLog("Markdowner: cycle — no on-Space workspace; opening new")
            openNewWorkspaceWindow(activate: false)
            return
        }

        // Stable order by window number so z-order reshuffles don’t collapse the cycle.
        let stable = onscreen.sorted { $0.windowNumber < $1.windowNumber }

        let target: NSWindow
        if !forceCycle || stable.count == 1 {
            // First bring-to-front / single window: CG front-to-back topmost on this Space.
            target = onscreen[0]
            NSLog("Markdowner: focus frontmost on-Space window #%d", target.windowNumber)
        } else {
            let keyOnThisSpace = onscreen.first(where: \.isKeyWindow)
                ?? onscreen.first(where: \.isMainWindow)
            let anchorNumber = lastCycledWindowNumber
                ?? keyOnThisSpace?.windowNumber
                ?? onscreen[0].windowNumber
            if let idx = stable.firstIndex(where: { $0.windowNumber == anchorNumber }) {
                target = stable[(idx + 1) % stable.count]
            } else {
                target = stable[0]
            }
            NSLog(
                "Markdowner: cycle next on-Space window #%d (of %d, anchor #%d)",
                target.windowNumber,
                stable.count,
                anchorNumber
            )
        }

        orderWorkspaceFrontPreservingSpace(target)
        lastCycledWindowNumber = target.windowNumber
    }

    /// Workspace `NSWindow`s whose CoreGraphics window is on-screen (current Space).
    private static func workspaceWindowsOnCurrentSpace() -> [NSWindow] {
        let onscreenIDs = onscreenWindowIDsForThisProcess()
        // Preserve CG front-to-back order among matches.
        var byNumber: [Int: NSWindow] = [:]
        for window in NSApp.windows where isWorkspaceWindow(window) {
            byNumber[window.windowNumber] = window
        }
        var ordered: [NSWindow] = []
        ordered.reserveCapacity(onscreenIDs.count)
        for id in onscreenIDs {
            if let window = byNumber[Int(id)] {
                ordered.append(window)
            }
        }
        // Fallback: if CG list is empty/partial (permissions), still allow in-process cycle of visible workspaces.
        if ordered.isEmpty {
            return NSApp.windows.filter { isWorkspaceWindow($0) && $0.isVisible && !$0.isMiniaturized }
        }
        return ordered
    }

    private static func onscreenWindowIDsForThisProcess() -> [CGWindowID] {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else {
            return []
        }
        var ids: [CGWindowID] = []
        for entry in info {
            let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t
                ?? (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard ownerPID == pid else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int
                ?? (entry[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? -1
            guard layer == 0 else { continue }

            var bounds = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) {
                bounds = rect
            }
            // Match ClingBar’s “real window” size floor.
            if bounds.width < 200 || bounds.height < 160 { continue }

            let windowID: CGWindowID? = {
                if let n = entry[kCGWindowNumber as String] as? CGWindowID { return n }
                if let n = entry[kCGWindowNumber as String] as? Int { return CGWindowID(n) }
                if let n = entry[kCGWindowNumber as String] as? NSNumber { return CGWindowID(n.uint32Value) }
                return nil
            }()
            if let windowID {
                ids.append(windowID)
            }
        }
        return ids
    }

    /// Raise a window that is already on this Space without first activating (avoids Space jump).
    private static func orderWorkspaceFrontPreservingSpace(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        // Order first, then activate — same pattern ClingBar uses for Finder.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        activateApp()
    }

    private static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
