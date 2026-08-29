import ObjectiveC
import UIKit

/// Delivers a real UIKit touch so WebKit treats media interaction as a user gesture.
/// Page buttons still need the JS bridge — synthetic touches alone are unreliable there.
enum NativeWebPointerInjector {
    private static var activeTouch: UITouch?
    private static weak var activeView: UIView?
    private static var activeEvent: UIEvent?

    @discardableResult
    static func begin(hostView: UIView, at pointInHost: CGPoint) -> Bool {
        cancel()
        guard let resolved = resolveTarget(hostView: hostView, pointInHost: pointInHost),
              let touch = makeTouch(view: resolved.view, window: resolved.window, atWindowPoint: resolved.pointInWindow),
              let event = touchesEvent()
        else {
            print("[FSWeb] native pointer begin failed @ \(pointInHost)")
            return false
        }

        setPhase(touch, .began)
        activeTouch = touch
        activeView = resolved.view
        activeEvent = event
        resolved.view.touchesBegan([touch], with: event)
        print("[FSWeb] native pointer DOWN → \(NSStringFromClass(type(of: resolved.view)))")
        return true
    }

    static func move(hostView: UIView, at pointInHost: CGPoint) {
        guard let touch = activeTouch, let view = activeView, let event = activeEvent else { return }
        guard let resolved = resolveTarget(hostView: hostView, pointInHost: pointInHost) else { return }
        updateLocation(touch, windowPoint: resolved.pointInWindow)
        setPhase(touch, .moved)
        view.touchesMoved([touch], with: event)
    }

    static func end() {
        guard let touch = activeTouch, let view = activeView, let event = activeEvent else {
            cancel()
            return
        }
        setPhase(touch, .ended)
        view.touchesEnded([touch], with: event)
        print("[FSWeb] native pointer UP → \(NSStringFromClass(type(of: view)))")
        clear()
    }

    static func cancel() {
        if let touch = activeTouch, let view = activeView, let event = activeEvent {
            setPhase(touch, .cancelled)
            view.touchesCancelled([touch], with: event)
        }
        clear()
    }

    private static func clear() {
        activeTouch = nil
        activeView = nil
        activeEvent = nil
    }

    /// Prefer frontmost window on the external scene (HTML/media fullscreen often adds one),
    /// and prefer `WKContentView` when present under the hit.
    private static func resolveTarget(
        hostView: UIView,
        pointInHost: CGPoint
    ) -> (view: UIView, window: UIWindow, pointInWindow: CGPoint)? {
        guard let baseWindow = hostView.window, let scene = baseWindow.windowScene else { return nil }
        let pointInBaseWindow = hostView.convert(pointInHost, to: nil)

        for window in scene.windows.reversed() {
            let pointInWindow = window.convert(pointInBaseWindow, from: baseWindow)
            guard let hit = window.hitTest(pointInWindow, with: nil) else { continue }

            let content = findWebKitContentView(from: hit) ?? findWebKitContentView(in: window)
            let target = content ?? hit
            return (target, window, pointInWindow)
        }
        return nil
    }

    private static func findWebKitContentView(from start: UIView) -> UIView? {
        var view: UIView? = start
        while let current = view {
            if NSStringFromClass(type(of: current)).contains("WKContentView") {
                return current
            }
            view = current.superview
        }
        return findWebKitContentView(in: start)
    }

    private static func findWebKitContentView(in root: UIView) -> UIView? {
        if NSStringFromClass(type(of: root)).contains("WKContentView") { return root }
        for sub in root.subviews {
            if let found = findWebKitContentView(in: sub) { return found }
        }
        return nil
    }

    private static func setPhase(_ touch: UITouch, _ phase: UITouch.Phase) {
        touch.setValue(NSNumber(value: phase.rawValue), forKey: "phase")
        touch.setValue(ProcessInfo.processInfo.systemUptime, forKey: "timestamp")
    }

    private static func updateLocation(_ touch: UITouch, windowPoint: CGPoint) {
        let selLoc = NSSelectorFromString("_setLocationInWindow:resetPrevious:")
        guard touch.responds(to: selLoc), let imp = touch.method(for: selLoc) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, CGPoint, Bool) -> Void
        unsafeBitCast(imp, to: Fn.self)(touch, selLoc, windowPoint, false)
    }

    private static func makeTouch(view: UIView, window: UIWindow, atWindowPoint point: CGPoint) -> UITouch? {
        let touch = UITouch()
        touch.setValue(view, forKey: "view")
        touch.setValue(window, forKey: "window")
        touch.setValue(1, forKey: "tapCount")
        touch.setValue(ProcessInfo.processInfo.systemUptime, forKey: "timestamp")
        touch.setValue(NSNumber(value: UITouch.Phase.began.rawValue), forKey: "phase")
        // Prefer indirectPointer so WebKit treats it closer to mouse than finger.
        if touch.responds(to: NSSelectorFromString("setType:")) {
            touch.setValue(NSNumber(value: UITouch.TouchType.indirectPointer.rawValue), forKey: "type")
        }

        let selLoc = NSSelectorFromString("_setLocationInWindow:resetPrevious:")
        guard touch.responds(to: selLoc), let imp = touch.method(for: selLoc) else {
            return nil
        }
        typealias Fn = @convention(c) (AnyObject, Selector, CGPoint, Bool) -> Void
        unsafeBitCast(imp, to: Fn.self)(touch, selLoc, point, true)
        return touch
    }

    private static func touchesEvent() -> UIEvent? {
        let app = UIApplication.shared
        let sel = NSSelectorFromString("_touchesEvent")
        guard app.responds(to: sel) else { return nil }
        return app.perform(sel)?.takeUnretainedValue() as? UIEvent
    }
}
