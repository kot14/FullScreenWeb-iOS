import ObjectiveC
import UIKit

/// Filters pointer clicks on the iPad *application* window while the external display owns the mouse.
///
/// IMPORTANT: Do NOT use `object_setClass` to turn SwiftUI/UIKit windows into a subclass —
/// that strips private methods like `actualSceneBounds` and crashes. We swizzle `sendEvent(_:)`
/// on `UIWindow` instead, preserving the real window class.
enum TouchOnlyWindowInstaller {
    private static var didSwizzle = false

    static func install() {
        guard !didSwizzle else { return }
        didSwizzle = true
        UIWindow.fs_swizzleSendEventIfNeeded()

        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            PointerDiagnostics.logKeyWindow(note.object as? UIWindow)
        }
    }
}

extension UIWindow {
    private static var fs_sendEventSwizzled = false

    fileprivate static func fs_swizzleSendEventIfNeeded() {
        guard !fs_sendEventSwizzled else { return }
        fs_sendEventSwizzled = true

        let original = #selector(sendEvent(_:))
        let replacement = #selector(fs_sendEvent(_:))
        guard
            let originalMethod = class_getInstanceMethod(UIWindow.self, original),
            let swizzleMethod = class_getInstanceMethod(UIWindow.self, replacement)
        else { return }
        method_exchangeImplementations(originalMethod, swizzleMethod)
    }

    /// Swizzled `sendEvent`. After exchange, calling `fs_sendEvent` invokes the real UIKit implementation.
    @objc func fs_sendEvent(_ event: UIEvent) {
        if fs_shouldFilterPointer(event) {
            return
        }
        fs_sendEvent(event)
    }

    private func fs_shouldFilterPointer(_ event: UIEvent) -> Bool {
        // Only the interactive iPad scene — never NonInteractive external / WebKit fullscreen windows.
        guard windowScene?.session.role == .windowApplication else { return false }

        if event.type == .hover {
            // Never swallow hover.
            return false
        }

        let store = WebViewStore.shared
        if store.isWebFullscreen { return false }
        guard store.isExternalDisplayConnected, store.captureMouseForExternalDisplay else {
            return false
        }

        if Self.fs_eventInvolvesWebKit(event) { return false }

        switch event.type {
        case .touches:
            return Self.fs_isPointerOnly(touches: event.allTouches)
        default:
            return false
        }
    }

    private static func fs_isPointerOnly(touches: Set<UITouch>?) -> Bool {
        guard let touches, !touches.isEmpty else { return false }
        let hasFingerOrPencil = touches.contains {
            $0.type == .direct || $0.type == .pencil
        }
        if hasFingerOrPencil { return false }
        return touches.allSatisfy {
            $0.type == .indirectPointer || $0.type == .indirect
        }
    }

    private static func fs_eventInvolvesWebKit(_ event: UIEvent) -> Bool {
        guard let touches = event.allTouches, !touches.isEmpty else { return false }
        for touch in touches {
            var view: UIView? = touch.view
            while let current = view {
                let name = NSStringFromClass(type(of: current))
                if name.contains("WKWebView") || name.contains("WKContentView") || name.contains("WKScrollView") {
                    return true
                }
                view = current.superview
            }
        }
        return false
    }
}

enum PointerDiagnostics {
    static func logKeyWindow(_ window: UIWindow?) {
        guard let window else {
            print("[FSWeb] key window = nil")
            return
        }
        let role = window.windowScene.map { String(describing: $0.session.role) } ?? "nil"
        let interactions = window.interactions.map { NSStringFromClass(type(of: $0)) }
        let rootInteractions = window.rootViewController?.view.interactions.map { NSStringFromClass(type(of: $0)) } ?? []
        print("[FSWeb] key window=\(NSStringFromClass(type(of: window))) role=\(role) isKey=\(window.isKeyWindow)")
        print("[FSWeb]   window.interactions=\(interactions)")
        print("[FSWeb]   rootView.interactions=\(rootInteractions)")
    }

    static func logSurface(_ label: String, view: UIView?) {
        guard let view else {
            print("[FSWeb] \(label): view=nil")
            return
        }
        let interactions = view.interactions.map { NSStringFromClass(type(of: $0)) }
        let hovers = view.gestureRecognizers?.compactMap { $0 as? UIHoverGestureRecognizer }.count ?? 0
        let windowDesc: String
        if let window = view.window {
            let role = window.windowScene.map { String(describing: $0.session.role) } ?? "?"
            windowDesc = "\(NSStringFromClass(type(of: window))) role=\(role)"
        } else {
            windowDesc = "nil"
        }
        print("[FSWeb] \(label): \(NSStringFromClass(type(of: view))) interactions=\(interactions) hoverRecognizers=\(hovers) window=\(windowDesc)")
    }
}
