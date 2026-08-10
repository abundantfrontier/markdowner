import AppKit
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
        NSApp.windows.filter { window in
            guard window.level == .normal, window.isVisible || window.isMiniaturized else { return false }
            let s = window.frame.size
            return s.width >= 700 && s.height >= 450
        }.count
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
        return false
    }

    private static func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
