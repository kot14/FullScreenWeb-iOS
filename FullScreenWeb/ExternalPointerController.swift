import Combine
import GameController
import UIKit
import WebKit

/// System pointer cannot enter NonInteractive external scenes.
/// Drives a software cursor from GCMouse (+ UIHover when the surface can deliver it).
/// On element fullscreen WebKit moves WKWebView into a new window on the same scene —
/// cursor follows once `webView.window` is non-nil (never touch UIPointerInteraction here).
final class ExternalPointerController: NSObject {
    private weak var hostView: UIView?
    private weak var canvasView: UIView?
    private weak var webView: WKWebView?
    private weak var urlField: UITextField?

    /// View that currently hosts the software cursor (normal host or fullscreen window).
    private weak var cursorSurface: UIView?
    private var hoverRecognizer: UIHoverGestureRecognizer?
    private var lastHoverLogTime: CFTimeInterval = 0
    private var fullscreenWindowRetry = 0

    private let cursorView = UIImageView()
    private var position: CGPoint = .zero
    private var urlFieldFocused = false
    private var shiftPressed = false
    private var lastPrimaryUpTime: CFTimeInterval = 0
    private var lastPrimaryUpPoint: CGPoint = .zero
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    var onURLSubmit: (() -> Void)?

    private var isCaptureEnabled: Bool {
        let store = WebViewStore.shared
        return store.isExternalDisplayConnected && store.captureMouseForExternalDisplay
    }

    private var activeSurface: UIView? { cursorSurface ?? hostView }

    func attach(
        hostView: UIView,
        canvasView: UIView,
        webView: WKWebView,
        urlField: UITextField
    ) {
        self.hostView = hostView
        self.canvasView = canvasView
        self.webView = webView
        self.urlField = urlField

        let cursorImage = Self.makeCursorImage()
        cursorView.image = cursorImage
        cursorView.contentMode = .topLeft
        cursorView.layer.shadowColor = UIColor.black.cgColor
        cursorView.layer.shadowOpacity = 0.35
        cursorView.layer.shadowRadius = 1
        cursorView.layer.shadowOffset = CGSize(width: 0.5, height: 0.5)
        cursorView.frame = CGRect(origin: .zero, size: cursorImage.size)
        cursorView.isUserInteractionEnabled = false

        position = CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY)
        rebindPointerSurface(reason: "attach")

        WebViewStore.shared.onExternalScroll = { [weak self] dx, dy, asPixels in
            self?.handleScroll(dx: dx, dy: dy, asPixels: asPixels)
        }

        WebViewStore.shared.$isExternalDisplayConnected
            .combineLatest(WebViewStore.shared.$captureMouseForExternalDisplay)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateCursor()
            }
            .store(in: &cancellables)

        startWatchingDevices()
        bindExistingDevices()
        startWatchingKeyWindows()
    }

    func detach() {
        NativeWebPointerInjector.cancel()
        tearDownHover()
        if WebViewStore.shared.onExternalScroll != nil {
            WebViewStore.shared.onExternalScroll = nil
        }
        cancellables.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        cursorView.removeFromSuperview()
        hostView = nil
        canvasView = nil
        webView = nil
        urlField = nil
        cursorSurface = nil
    }

    func hostDidLayout() {
        clampPosition()
        updateCursor()
    }

    /// WebKit moves WKWebView into a fullscreen window on the *same* UIWindowScene.
    /// On NonInteractive external that window cannot take a system pointer; we only
    /// rebind the software cursor once `webView.window != nil`.
    func handleFullscreenStateChanged(_ webView: WKWebView) {
        let state = webView.fullscreenState
        let inFS = state == .inFullscreen || state == .enteringFullscreen
        WebViewStore.shared.isWebFullscreen = inFS

        let window = webView.window
        let role = window?.windowScene.map { String(describing: $0.session.role) } ?? "nil"
        print("[FSWeb] fullscreenState=\(String(describing: state)) inFS=\(inFS) webView.window=\(window.map { NSStringFromClass(type(of: $0)) } ?? "nil") role=\(role)")

        // Keep the interactive application window as key (pointer/hover live there).
        ensureApplicationWindowIsKey()
        PointerDiagnostics.logKeyWindow(Self.keyWindow())

        if inFS, window == nil {
            // Transition: WebKit has detached the web view; wait for the fullscreen window.
            fullscreenWindowRetry += 1
            guard fullscreenWindowRetry <= 20 else {
                print("[FSWeb] fullscreen: webView.window still nil after retries — staying on host surface")
                rebindPointerSurface(reason: "fullscreen-nil-timeout")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.handleFullscreenStateChanged(webView)
            }
            return
        }

        fullscreenWindowRetry = 0

        if let window, Self.isNonInteractive(window) {
            print("[FSWeb] fullscreen is on NonInteractive scene — system cursor cannot enter; software cursor + GCMouse only")
        }

        rebindPointerSurface(reason: "fullscreenState")
    }

    // MARK: - Pointer surface (normal vs fullscreen window)

    private func rebindPointerSurface(reason: String) {
        let surface: UIView
        if let webView, let window = webView.window {
            if Self.isSnapshotLike(window) {
                print("[FSWeb] skip snapshot-like window \(NSStringFromClass(type(of: window))) (\(reason))")
                surface = hostView ?? window
            } else if WebViewStore.shared.isWebFullscreen || window !== hostView?.window {
                surface = window
            } else if let hostView {
                surface = hostView
            } else {
                surface = window
            }
        } else if let hostView {
            surface = hostView
        } else {
            return
        }

        if cursorSurface !== surface {
            print("[FSWeb] cursor surface ← \(NSStringFromClass(type(of: surface))) (\(reason))")
            cursorSurface = surface
            cursorView.removeFromSuperview()
            surface.addSubview(cursorView)
            position = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        }

        // Hover only — never UIPointerInteraction here (triggers actualSceneBounds on
        // NonInteractive / snapshot windows). iPad UIPointerInteraction is left alone.
        if let webView, webView.window != nil {
            installHover(on: webView)
        } else {
            installHover(on: surface)
        }

        clampPosition()
        updateCursor()
        PointerDiagnostics.logSurface("pointer surface", view: surface)
        PointerDiagnostics.logSurface("webView", view: webView)
    }

    private func installHover(on target: UIView) {
        tearDownHover()
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hoverRecognizer = hover
        target.addGestureRecognizer(hover)
        print("[FSWeb] installed UIHover on \(NSStringFromClass(type(of: target)))")
    }

    private func tearDownHover() {
        if let hoverRecognizer {
            hoverRecognizer.view?.removeGestureRecognizer(hoverRecognizer)
        }
        hoverRecognizer = nil
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard isCaptureEnabled, let surface = activeSurface else { return }
        let point = recognizer.location(in: surface)
        switch recognizer.state {
        case .began, .changed:
            position = point
            clampPosition()
            updateCursor()
            NativeWebPointerInjector.move(hostView: surface, at: position)
            forwardHoverToWeb()
            let now = CACurrentMediaTime()
            if now - lastHoverLogTime > 0.5 {
                lastHoverLogTime = now
                print("[FSWeb] UIHover \(recognizer.state.rawValue) @ \(String(format: "%.1f,%.1f", point.x, point.y)) surface=\(NSStringFromClass(type(of: surface)))")
            }
        case .ended, .cancelled:
            print("[FSWeb] UIHover ended/cancelled")
        default:
            break
        }
    }

    private func startWatchingKeyWindows() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let window = note.object as? UIWindow
            PointerDiagnostics.logKeyWindow(window)
            if let window, Self.isNonInteractive(window) {
                print("[FSWeb] NonInteractive window became key — restoring application key")
                self?.ensureApplicationWindowIsKey()
            }
            if WebViewStore.shared.isWebFullscreen {
                self?.rebindPointerSurface(reason: "didBecomeKey")
            }
        })
    }

    private func ensureApplicationWindowIsKey() {
        if let key = Self.keyWindow(), !Self.isNonInteractive(key) { return }
        let candidate = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
            .flatMap(\.windows)
            .first { !$0.isHidden }
        candidate?.makeKey()
        if let candidate {
            print("[FSWeb] application window made key: \(NSStringFromClass(type(of: candidate)))")
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private static func isNonInteractive(_ window: UIWindow) -> Bool {
        window.windowScene?.session.role == .windowExternalDisplayNonInteractive
    }

    private static func isSnapshotLike(_ window: UIWindow) -> Bool {
        let name = NSStringFromClass(type(of: window))
        return name.contains("Snapshot") || name.contains("Remote")
    }

    // MARK: - Devices

    private func startWatchingDevices() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.bindMouse(note.object as? GCMouse)
        })
        observers.append(center.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.bindKeyboard(GCKeyboard.coalesced)
        })
    }

    private func bindExistingDevices() {
        GCMouse.mice().forEach(bindMouse)
        bindKeyboard(GCKeyboard.coalesced)
    }

    private func bindMouse(_ mouse: GCMouse?) {
        guard let input = mouse?.mouseInput else { return }

        input.mouseMovedHandler = { [weak self] _, dx, dy in
            guard let self, self.isCaptureEnabled, let surface = self.activeSurface else { return }
            self.position.x += CGFloat(dx)
            self.position.y -= CGFloat(dy)
            self.clampPosition()
            self.updateCursor()
            NativeWebPointerInjector.move(hostView: surface, at: self.position)
            self.forwardHoverToWeb()
        }

        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            guard let self, self.isCaptureEnabled else { return }
            if pressed { self.handlePrimaryDown() }
            else { self.handlePrimaryUp() }
        }

        input.scroll.yAxis.valueChangedHandler = { [weak self] _, value in
            guard let self, self.isCaptureEnabled else { return }
            guard abs(value) >= 0.5 else { return }
            self.handleScroll(dx: 0, dy: CGFloat(value.rounded()), asPixels: false)
        }
        input.scroll.xAxis.valueChangedHandler = { [weak self] _, value in
            guard let self, self.isCaptureEnabled else { return }
            guard abs(value) >= 0.5 else { return }
            self.handleScroll(dx: CGFloat(value.rounded()), dy: 0, asPixels: false)
        }
    }

    private func bindKeyboard(_ keyboard: GCKeyboard?) {
        guard let input = keyboard?.keyboardInput else { return }

        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            guard let self, self.isCaptureEnabled else { return }
            self.handleKey(keyCode: keyCode, pressed: pressed)
        }
    }

    // MARK: - Cursor

    /// Classic arrow pointer: white fill, dark outline, tip at (0, 0) = click hotspot.
    private static func makeCursorImage() -> UIImage {
        let size = CGSize(width: 18, height: 24)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0.75, y: 0.75))
            path.addLine(to: CGPoint(x: 0.75, y: 18.5))
            path.addLine(to: CGPoint(x: 5.2, y: 14.2))
            path.addLine(to: CGPoint(x: 8.4, y: 22.2))
            path.addLine(to: CGPoint(x: 10.9, y: 21.1))
            path.addLine(to: CGPoint(x: 7.6, y: 13.1))
            path.addLine(to: CGPoint(x: 14.2, y: 13.1))
            path.close()

            UIColor.white.setFill()
            path.fill()

            UIColor.black.setStroke()
            path.lineWidth = 1.1
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    private func clampPosition() {
        guard let host = activeSurface else { return }
        position.x = min(max(0, position.x), host.bounds.width)
        position.y = min(max(0, position.y), host.bounds.height)
    }

    private func updateCursor() {
        cursorView.isHidden = !isCaptureEnabled
        cursorView.frame.origin = CGPoint(x: position.x, y: position.y)
        activeSurface?.bringSubviewToFront(cursorView)
    }

    private func webViewPoint() -> CGPoint? {
        guard let surface = activeSurface, let webView, webView.window != nil else { return nil }
        let local = webView.convert(position, from: surface)
        guard webView.bounds.contains(local) else { return nil }
        return local
    }

    // MARK: - Clicks

    private func handlePrimaryDown() {
        guard let host = hostView, let canvas = canvasView, let surface = activeSurface else { return }

        if !WebViewStore.shared.isWebFullscreen {
            let hostPoint = host.convert(position, from: surface)
            if tryActivateControl(in: host, at: hostPoint, ignoring: [canvas, webView].compactMap { $0 }) {
                return
            }
            let canvasPoint = canvas.convert(position, from: surface)
            if tryActivateControl(in: canvas, at: canvasPoint, ignoring: [webView].compactMap { $0 }) {
                return
            }
        }

        focusURLField(false)
        // Native touch = WebKit user gesture (media). JS events = reliable DOM clicks
        // (synthetic UITouch alone often does not activate page buttons).
        NativeWebPointerInjector.begin(hostView: surface, at: position)
        guard let local = webViewPoint() else { return }
        dispatchWebClick(at: local, phase: .down)
    }

    @discardableResult
    private func tryActivateControl(in root: UIView, at point: CGPoint, ignoring: [UIView]) -> Bool {
        guard let hit = root.hitTest(point, with: nil), hit !== root else { return false }
        if ignoring.contains(where: { hit === $0 || hit.isDescendant(of: $0) }) { return false }
        if let field = hit as? UITextField ?? hit.superview as? UITextField {
            focusURLField(true)
            field.becomeFirstResponder()
            return true
        }
        var view: UIView? = hit
        while let current = view, current !== root {
            if let control = current as? UIControl {
                focusURLField(false)
                control.sendActions(for: [.touchUpInside, .primaryActionTriggered])
                return true
            }
            view = current.superview
        }
        return false
    }

    private func handlePrimaryUp() {
        NativeWebPointerInjector.end()

        // Double-click while WK element fullscreen → exit (backup if JS miss).
        if WebViewStore.shared.isWebFullscreen {
            let now = CACurrentMediaTime()
            let dist = hypot(position.x - lastPrimaryUpPoint.x, position.y - lastPrimaryUpPoint.y)
            if now - lastPrimaryUpTime <= 0.4, dist <= 28 {
                lastPrimaryUpTime = 0
                if let local = webViewPoint() {
                    dispatchWebPointer(at: local, phase: .up)
                }
                exitWebFullscreen()
                return
            }
            lastPrimaryUpTime = now
            lastPrimaryUpPoint = position
        } else {
            lastPrimaryUpTime = 0
        }

        guard let local = webViewPoint() else { return }
        dispatchWebClick(at: local, phase: .up)
    }

    private func exitWebFullscreen() {
        print("[FSWeb] exitWebFullscreen (native closeAllMediaPresentations)")
        // Element/media fullscreen is an out-of-window WK presentation — JS alone won't dismiss it.
        webView?.closeAllMediaPresentations {
            print("[FSWeb] closeAllMediaPresentations done")
        }

        let js = """
        (function() {
          var results = [];
          try {
            var d = document;
            var fs = d.fullscreenElement || d.webkitFullscreenElement;
            if (fs) {
              if (d.exitFullscreen) { d.exitFullscreen(); results.push('exit'); }
              else if (d.webkitExitFullscreen) { d.webkitExitFullscreen(); results.push('webkitExit'); }
            }
            var videos = d.querySelectorAll('video');
            for (var i = 0; i < videos.length; i++) {
              var v = videos[i];
              if (v.webkitDisplayingFullscreen && v.webkitExitFullscreen) {
                v.webkitExitFullscreen();
                results.push('videoExit');
              }
            }
            var frames = d.querySelectorAll('iframe');
            for (var i = 0; i < frames.length; i++) {
              try {
                frames[i].contentWindow.postMessage({ __fsPointer: true, phase: 'exitFullscreen', x: 0, y: 0 }, '*');
              } catch (e) {}
            }
          } catch (e) { return 'err:' + e; }
          return results.join(',') || 'none';
        })();
        """
        webView?.evaluateJavaScript(js) { result, error in
            if let error {
                print("[FSWeb] exitFullscreen JS error=\(error.localizedDescription)")
            } else {
                print("[FSWeb] exitFullscreen JS → \(result ?? "?")")
            }
        }
    }

    private func focusURLField(_ focused: Bool) {
        urlFieldFocused = focused
        urlField?.backgroundColor = focused ? UIColor(white: 0.95, alpha: 1) : .white
        if !focused {
            urlField?.resignFirstResponder()
        }
    }

    private func handleScroll(dx: CGFloat, dy: CGFloat, asPixels: Bool) {
        guard webView != nil else { return }
        let scale: CGFloat = asPixels ? 1 : 64
        let pixelX = dx * scale
        let pixelY = dy * scale

        if let scroll = webView?.scrollView {
            var offset = scroll.contentOffset
            offset.x -= pixelX
            offset.y -= pixelY
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width)
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            offset.x = min(max(-scroll.adjustedContentInset.left, offset.x), maxX)
            offset.y = min(max(-scroll.adjustedContentInset.top, offset.y), maxY)
            scroll.setContentOffset(offset, animated: false)
        }

        dispatchWebWheel(deltaX: -pixelX, deltaY: -pixelY)
    }

    private func dispatchWebWheel(deltaX: CGFloat, deltaY: CGFloat) {
        guard let surface = activeSurface, let webView, webView.window != nil else { return }
        let local = webView.convert(position, from: surface)
        guard webView.bounds.contains(local) else {
            webView.evaluateJavaScript(
                "window.scrollBy({ left: \(deltaX), top: \(deltaY), behavior: 'instant' });",
                completionHandler: nil
            )
            return
        }

        let x = local.x
        let y = local.y
        let js = """
        (function() {
          var dx = \(deltaX), dy = \(deltaY), x = \(x), y = \(y);
          var el = document.elementFromPoint(x, y);
          var node = el;
          while (node && node !== document.body && node !== document.documentElement) {
            var style = window.getComputedStyle(node);
            var ox = style.overflowX, oy = style.overflowY;
            var canX = (ox === 'auto' || ox === 'scroll' || ox === 'overlay') && node.scrollWidth > node.clientWidth + 1;
            var canY = (oy === 'auto' || oy === 'scroll' || oy === 'overlay') && node.scrollHeight > node.clientHeight + 1;
            if (canX || canY) {
              node.scrollBy({ left: dx, top: dy, behavior: 'instant' });
              return;
            }
            node = node.parentElement;
          }
          var target = el || document.body;
          var evt = new WheelEvent('wheel', {
            deltaX: dx, deltaY: dy, deltaMode: 0,
            bubbles: true, cancelable: true, clientX: x, clientY: y, view: window
          });
          target.dispatchEvent(evt);
          if (!evt.defaultPrevented) {
            window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
          }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func forwardHoverToWeb() {
        guard let local = webViewPoint() else { return }
        dispatchWebPointer(at: local, phase: .move)
    }

    private enum PointerPhase: String {
        case down, up, move
    }

    private func dispatchWebPointer(at local: CGPoint, phase: PointerPhase) {
        guard let webView, webView.window != nil else { return }
        let js = "window.__fsPointerEvent && window.__fsPointerEvent('\(phase.rawValue)', \(local.x), \(local.y));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func dispatchWebClick(at local: CGPoint, phase: ClickPhase) {
        dispatchWebPointer(at: local, phase: phase == .down ? .down : .up)
    }

    private enum ClickPhase { case down, up }

    // MARK: - Keyboard

    private func handleKey(keyCode: GCKeyCode, pressed: Bool) {
        if keyCode == .leftShift || keyCode == .rightShift {
            shiftPressed = pressed
            return
        }
        guard pressed else { return }

        if keyCode == .returnOrEnter {
            if urlFieldFocused {
                onURLSubmit?()
                focusURLField(false)
            } else {
                dispatchWebEnter()
            }
            return
        }

        if keyCode == .deleteOrBackspace {
            if urlFieldFocused, let field = urlField, let text = field.text, !text.isEmpty {
                moveOrEditURLFieldBackspace(in: field, text: text)
            } else {
                dispatchWebBackspace()
            }
            return
        }

        if keyCode == .escape {
            focusURLField(false)
            return
        }

        if keyCode == .tab {
            focusURLField(true)
            urlField?.becomeFirstResponder()
            return
        }

        switch keyCode {
        case .upArrow, .downArrow, .leftArrow, .rightArrow:
            handleArrowKey(keyCode)
            return
        case .pageUp where !urlFieldFocused:
            handleScroll(dx: 0, dy: 4, asPixels: false)
            return
        case .pageDown where !urlFieldFocused:
            handleScroll(dx: 0, dy: -4, asPixels: false)
            return
        case .home where !urlFieldFocused:
            dispatchWebCaretCommand("home") { [weak self] handled in
                if !handled {
                    self?.webView?.scrollView.setContentOffset(
                        CGPoint(x: self?.webView?.scrollView.contentOffset.x ?? 0, y: 0),
                        animated: true
                    )
                }
            }
            return
        case .end where !urlFieldFocused:
            dispatchWebCaretCommand("end") { [weak self] handled in
                guard !handled, let scroll = self?.webView?.scrollView else { return }
                let y = max(0, scroll.contentSize.height - scroll.bounds.height)
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
            }
            return
        default:
            break
        }

        guard let character = Self.character(for: keyCode, shift: shiftPressed) else { return }

        if urlFieldFocused, let field = urlField {
            insertURLFieldText(character, in: field)
            return
        }

        dispatchWebText(character)
    }

    private func handleArrowKey(_ keyCode: GCKeyCode) {
        let direction: String
        switch keyCode {
        case .upArrow: direction = "up"
        case .downArrow: direction = "down"
        case .leftArrow: direction = "left"
        case .rightArrow: direction = "right"
        default: return
        }

        if urlFieldFocused, let field = urlField {
            moveURLFieldCaret(direction: direction, in: field)
            return
        }

        dispatchWebCaretCommand(direction) { [weak self] handled in
            guard !handled else { return }
            switch keyCode {
            case .upArrow: self?.handleScroll(dx: 0, dy: 1, asPixels: false)
            case .downArrow: self?.handleScroll(dx: 0, dy: -1, asPixels: false)
            case .leftArrow: self?.handleScroll(dx: 1, dy: 0, asPixels: false)
            case .rightArrow: self?.handleScroll(dx: -1, dy: 0, asPixels: false)
            default: break
            }
        }
    }

    private func moveURLFieldCaret(direction: String, in field: UITextField) {
        let text = field.text ?? ""
        let length = text.count
        let startOffset: Int
        let endOffset: Int
        if let range = field.selectedTextRange {
            startOffset = field.offset(from: field.beginningOfDocument, to: range.start)
            endOffset = field.offset(from: field.beginningOfDocument, to: range.end)
        } else {
            startOffset = length
            endOffset = length
        }

        let newOffset: Int
        switch direction {
        case "left":
            newOffset = startOffset != endOffset ? min(startOffset, endOffset) : max(0, startOffset - 1)
        case "right":
            newOffset = startOffset != endOffset ? max(startOffset, endOffset) : min(length, endOffset + 1)
        case "up", "home":
            newOffset = 0
        case "down", "end":
            newOffset = length
        default:
            return
        }

        guard let position = field.position(from: field.beginningOfDocument, offset: newOffset) else { return }
        field.selectedTextRange = field.textRange(from: position, to: position)
    }

    private func insertURLFieldText(_ character: String, in field: UITextField) {
        let text = field.text ?? ""
        if let range = field.selectedTextRange, !range.isEmpty {
            field.replace(range, withText: character)
            return
        }
        if let range = field.selectedTextRange {
            field.replace(range, withText: character)
        } else {
            field.text = text + character
        }
    }

    private func moveOrEditURLFieldBackspace(in field: UITextField, text: String) {
        if let range = field.selectedTextRange, !range.isEmpty {
            field.replace(range, withText: "")
            return
        }
        guard let selected = field.selectedTextRange else {
            field.text = String(text.dropLast())
            return
        }
        let cursor = field.offset(from: field.beginningOfDocument, to: selected.start)
        guard cursor > 0,
              let start = field.position(from: field.beginningOfDocument, offset: cursor - 1),
              let end = field.position(from: field.beginningOfDocument, offset: cursor),
              let deleteRange = field.textRange(from: start, to: end)
        else { return }
        field.replace(deleteRange, withText: "")
    }

    private func dispatchWebEnter() {
        let js = """
        (function() {
          var el = document.activeElement;
          if (!el) return;
          var opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
          if (!el.dispatchEvent(new KeyboardEvent('keydown', opts))) return;
          el.dispatchEvent(new KeyboardEvent('keypress', opts));

          if (el.tagName === 'TEXTAREA') {
            var start = el.selectionStart, end = el.selectionEnd;
            if (typeof start === 'number' && typeof end === 'number') {
              el.value = el.value.slice(0, start) + '\\n' + el.value.slice(end);
              el.selectionStart = el.selectionEnd = start + 1;
              el.dispatchEvent(new Event('input', { bubbles: true }));
            }
          } else if (el.isContentEditable) {
            document.execCommand('insertLineBreak', false, null);
          } else if (el.tagName === 'INPUT') {
            var form = el.form;
            if (form) {
              if (typeof form.requestSubmit === 'function') {
                try { form.requestSubmit(); } catch (e) { form.submit(); }
              } else {
                var btn = form.querySelector('button[type="submit"], input[type="submit"]');
                if (btn) btn.click();
                else form.submit();
              }
            }
          }

          el.dispatchEvent(new KeyboardEvent('keyup', opts));
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func dispatchWebCaretCommand(_ direction: String, completion: ((Bool) -> Void)? = nil) {
        let js = """
        (function() {
          var el = document.activeElement;
          if (!el) return false;

          function isEditable(node) {
            if (!node) return false;
            if (node.isContentEditable) return true;
            var tag = node.tagName;
            if (tag === 'TEXTAREA') return true;
            if (tag === 'INPUT') {
              var t = (node.type || 'text').toLowerCase();
              return ['text','search','url','tel','email','password','number','']
                .indexOf(t) >= 0;
            }
            return false;
          }

          if (!isEditable(el)) return false;

          var dir = '\(direction)';
          var opts = {
            key: dir === 'left' ? 'ArrowLeft' :
                 dir === 'right' ? 'ArrowRight' :
                 dir === 'up' ? 'ArrowUp' :
                 dir === 'down' ? 'ArrowDown' :
                 dir === 'home' ? 'Home' : 'End',
            bubbles: true, cancelable: true
          };
          if (!el.dispatchEvent(new KeyboardEvent('keydown', opts))) return true;

          if (el.isContentEditable) {
            var sel = window.getSelection();
            if (!sel) return true;
            if (dir === 'left') sel.modify('move', 'backward', 'character');
            else if (dir === 'right') sel.modify('move', 'forward', 'character');
            else if (dir === 'up') sel.modify('move', 'backward', 'line');
            else if (dir === 'down') sel.modify('move', 'forward', 'line');
            else if (dir === 'home') sel.modify('move', 'backward', 'lineboundary');
            else if (dir === 'end') sel.modify('move', 'forward', 'lineboundary');
            return true;
          }

          var start = el.selectionStart, end = el.selectionEnd;
          if (typeof start !== 'number' || typeof end !== 'number') return true;
          var value = el.value || '';
          var len = value.length;

          function columnOf(pos) {
            return pos - (value.lastIndexOf('\\n', pos - 1) + 1);
          }
          function moveVertical(delta) {
            var pos = start === end ? start : (delta < 0 ? start : end);
            var col = columnOf(pos);
            if (delta < 0) {
              var prevNl = value.lastIndexOf('\\n', pos - 1);
              if (prevNl < 0) { el.selectionStart = el.selectionEnd = 0; return; }
              var prevPrev = value.lastIndexOf('\\n', prevNl - 1);
              var lineStart = prevPrev + 1;
              var prevLen = prevNl - lineStart;
              var next = lineStart + Math.min(col, prevLen);
              el.selectionStart = el.selectionEnd = next;
            } else {
              var nextNl = value.indexOf('\\n', pos);
              if (nextNl < 0) { el.selectionStart = el.selectionEnd = len; return; }
              var nextNext = value.indexOf('\\n', nextNl + 1);
              var lineStart2 = nextNl + 1;
              var lineEnd = nextNext < 0 ? len : nextNext;
              var nextLen = lineEnd - lineStart2;
              el.selectionStart = el.selectionEnd = lineStart2 + Math.min(col, nextLen);
            }
          }

          if (dir === 'left') {
            if (start !== end) el.selectionStart = el.selectionEnd = Math.min(start, end);
            else el.selectionStart = el.selectionEnd = Math.max(0, start - 1);
          } else if (dir === 'right') {
            if (start !== end) el.selectionStart = el.selectionEnd = Math.max(start, end);
            else el.selectionStart = el.selectionEnd = Math.min(len, end + 1);
          } else if (dir === 'up') {
            if (el.tagName === 'TEXTAREA') moveVertical(-1);
            else el.selectionStart = el.selectionEnd = 0;
          } else if (dir === 'down') {
            if (el.tagName === 'TEXTAREA') moveVertical(1);
            else el.selectionStart = el.selectionEnd = len;
          } else if (dir === 'home') {
            if (el.tagName === 'TEXTAREA') {
              var lineStart = value.lastIndexOf('\\n', start - 1) + 1;
              el.selectionStart = el.selectionEnd = lineStart;
            } else {
              el.selectionStart = el.selectionEnd = 0;
            }
          } else if (dir === 'end') {
            if (el.tagName === 'TEXTAREA') {
              var nl = value.indexOf('\\n', end);
              el.selectionStart = el.selectionEnd = nl < 0 ? len : nl;
            } else {
              el.selectionStart = el.selectionEnd = len;
            }
          }
          return true;
        })();
        """
        webView?.evaluateJavaScript(js) { result, _ in
            completion?((result as? Bool) ?? false)
        }
    }

    private func dispatchWebBackspace() {
        let js = """
        (function() {
          var el = document.activeElement;
          if (!el) return;
          el.dispatchEvent(new KeyboardEvent('keydown', {
            key: 'Backspace', code: 'Backspace', keyCode: 8, which: 8, bubbles: true, cancelable: true
          }));
          if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
            var start = el.selectionStart, end = el.selectionEnd;
            if (typeof start === 'number' && typeof end === 'number') {
              if (start === end && start > 0) {
                el.value = el.value.slice(0, start - 1) + el.value.slice(end);
                el.selectionStart = el.selectionEnd = start - 1;
              } else if (start !== end) {
                el.value = el.value.slice(0, start) + el.value.slice(end);
                el.selectionStart = el.selectionEnd = start;
              }
              el.dispatchEvent(new Event('input', { bubbles: true }));
              return;
            }
            if (typeof el.value === 'string' && el.value.length > 0) {
              el.value = el.value.slice(0, -1);
              el.dispatchEvent(new Event('input', { bubbles: true }));
            }
            return;
          }
          if (el.isContentEditable) {
            document.execCommand('delete', false, null);
          }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func dispatchWebText(_ text: String) {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
          var el = document.activeElement;
          if (!el) return;
          if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
            var start = el.selectionStart, end = el.selectionEnd;
            if (typeof start === 'number' && typeof end === 'number') {
              el.value = el.value.slice(0, start) + '\(escaped)' + el.value.slice(end);
              el.selectionStart = el.selectionEnd = start + \(text.count);
              el.dispatchEvent(new Event('input', { bubbles: true }));
              return;
            }
            if (typeof el.value === 'string') {
              el.value += '\(escaped)';
              el.dispatchEvent(new Event('input', { bubbles: true }));
            }
            return;
          }
          if (el.isContentEditable) {
            document.execCommand('insertText', false, '\(escaped)');
          }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private static func character(for keyCode: GCKeyCode, shift: Bool) -> String? {
        let map: [GCKeyCode: (String, String)] = [
            .keyA: ("a", "A"), .keyB: ("b", "B"), .keyC: ("c", "C"), .keyD: ("d", "D"),
            .keyE: ("e", "E"), .keyF: ("f", "F"), .keyG: ("g", "G"), .keyH: ("h", "H"),
            .keyI: ("i", "I"), .keyJ: ("j", "J"), .keyK: ("k", "K"), .keyL: ("l", "L"),
            .keyM: ("m", "M"), .keyN: ("n", "N"), .keyO: ("o", "O"), .keyP: ("p", "P"),
            .keyQ: ("q", "Q"), .keyR: ("r", "R"), .keyS: ("s", "S"), .keyT: ("t", "T"),
            .keyU: ("u", "U"), .keyV: ("v", "V"), .keyW: ("w", "W"), .keyX: ("x", "X"),
            .keyY: ("y", "Y"), .keyZ: ("z", "Z"),
            .one: ("1", "!"), .two: ("2", "@"), .three: ("3", "#"), .four: ("4", "$"),
            .five: ("5", "%"), .six: ("6", "^"), .seven: ("7", "&"), .eight: ("8", "*"),
            .nine: ("9", "("), .zero: ("0", ")"),
            .spacebar: (" ", " "),
            .hyphen: ("-", "_"), .equalSign: ("=", "+"),
            .openBracket: ("[", "{"), .closeBracket: ("]", "}"),
            .backslash: ("\\", "|"), .semicolon: (";", ":"),
            .quote: ("'", "\""), .comma: (",", "<"),
            .period: (".", ">"), .slash: ("/", "?"),
            .graveAccentAndTilde: ("`", "~")
        ]
        guard let pair = map[keyCode] else { return nil }
        return shift ? pair.1 : pair.0
    }
}
