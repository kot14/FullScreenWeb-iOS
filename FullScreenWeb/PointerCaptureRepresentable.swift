import Combine
import SwiftUI
import UIKit

/// Hosts iPad controls. Mouse is locked/hidden while the external display owns input,
/// except during WKWebView element fullscreen (must stay pointer-capable — no cursor hide).
/// Scroll-wheel/trackpad events are captured here and forwarded to the monitor.
struct PointerCaptureHost<Content: View>: UIViewControllerRepresentable {
    var lockPointer: Bool
    @ViewBuilder var content: () -> Content

    func makeUIViewController(context: Context) -> TouchOnlyHostController<Content> {
        TouchOnlyWindowInstaller.install()
        return TouchOnlyHostController(rootView: content())
    }

    func updateUIViewController(_ controller: TouchOnlyHostController<Content>, context: Context) {
        controller.rootView = content()
        controller.setPointerLocked(lockPointer)
    }
}

final class TouchOnlyHostController<Content: View>: UIViewController, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
    private let hostingController: UIHostingController<Content>
    private var lockPointer = false
    private var pointerInteraction: UIPointerInteraction?
    private var scrollPan: UIPanGestureRecognizer?
    private var lastScrollTranslation: CGPoint = .zero
    private var lockObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    /// Hide/lock only when capturing for external AND not in web element fullscreen.
    private var shouldSuppressSystemCursor: Bool {
        lockPointer && !WebViewStore.shared.isWebFullscreen
    }

    /// Wheel/trackpad should go to the external browser — not the iPad settings ScrollView.
    private var shouldCaptureScrollForExternal: Bool {
        lockPointer && !WebViewStore.shared.isWebFullscreen
    }

    var rootView: Content {
        get { hostingController.rootView }
        set { hostingController.rootView = newValue }
    }

    init(rootView: Content) {
        hostingController = UIHostingController(rootView: rootView)
        hostingController.view.backgroundColor = .clear
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let lockObserver {
            NotificationCenter.default.removeObserver(lockObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        addChild(hostingController)
        let hosted = hostingController.view!
        hosted.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.topAnchor.constraint(equalTo: view.topAnchor),
            hosted.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosted.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)

        // Keep UIPointerInteraction installed — never remove it in fullscreen.
        // Style returns nil while web fullscreen so the pointer stays visible/capable.
        let pointer = UIPointerInteraction(delegate: self)
        pointerInteraction = pointer
        view.addInteraction(pointer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        pan.allowedScrollTypesMask = .all
        pan.maximumNumberOfTouches = 0
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        scrollPan = pan
        view.addGestureRecognizer(pan)

        lockObserver = NotificationCenter.default.addObserver(
            forName: UIPointerLockState.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPointerChrome()
        }

        WebViewStore.shared.$isWebFullscreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inFullscreen in
                print("[FSWeb] iPad pointer: isWebFullscreen=\(inFullscreen) → suppressCursor=\(self?.shouldSuppressSystemCursor ?? false)")
                self?.setNeedsUpdateOfPrefersPointerLocked()
                self?.refreshPointerChrome()
                self?.applyScrollCapturePolicy()
            }
            .store(in: &cancellables)

        applyScrollCapturePolicy()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfPrefersPointerLocked()
        applyScrollCapturePolicy()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // SwiftUI may recreate UIScrollView after updates — re-apply wheel blocking.
        applyScrollCapturePolicy()
    }

    override var childViewControllerForPointerLock: UIViewController? { nil }

    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { nil }

    override var prefersPointerLocked: Bool { shouldSuppressSystemCursor }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        shouldSuppressSystemCursor ? .all : []
    }

    override var prefersStatusBarHidden: Bool { shouldSuppressSystemCursor }

    func setPointerLocked(_ locked: Bool) {
        guard lockPointer != locked else {
            setNeedsUpdateOfPrefersPointerLocked()
            applyScrollCapturePolicy()
            return
        }
        lockPointer = locked
        setNeedsUpdateOfPrefersPointerLocked()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        setNeedsStatusBarAppearanceUpdate()
        applyScrollCapturePolicy()
        refreshPointerChrome()
    }

    /// Finger can still drag iPad ScrollViews; mouse wheel / trackpad is claimed for the monitor.
    private func applyScrollCapturePolicy() {
        let capture = shouldCaptureScrollForExternal
        scrollPan?.isEnabled = capture
        Self.setScrollTypesEnabled(!capture, in: view)
    }

    private static func setScrollTypesEnabled(_ enabled: Bool, in root: UIView) {
        let mask: UIScrollTypeMask = enabled ? .all : []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView {
                scroll.panGestureRecognizer.allowedScrollTypesMask = mask
            }
            view.subviews.forEach(walk)
        }
        walk(root)
    }

    private func refreshPointerChrome() {
        // Re-query regions/styles — do not remove the interaction in fullscreen.
        if let pointerInteraction {
            view.removeInteraction(pointerInteraction)
            view.addInteraction(pointerInteraction)
        }
    }

    // MARK: - Scroll forward

    @objc private func handleScrollPan(_ pan: UIPanGestureRecognizer) {
        guard shouldCaptureScrollForExternal else { return }
        let translation = pan.translation(in: view)
        switch pan.state {
        case .began:
            lastScrollTranslation = translation
        case .changed:
            let dx = translation.x - lastScrollTranslation.x
            let dy = translation.y - lastScrollTranslation.y
            lastScrollTranslation = translation
            guard abs(dx) > 0.01 || abs(dy) > 0.01 else { return }
            // Pan translation Y is opposite to web content offset / wheel deltaY convention.
            WebViewStore.shared.forwardScroll(dx: dx, dy: -dy, asPixels: true)
        case .ended, .cancelled, .failed:
            lastScrollTranslation = .zero
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Scroll-wheel / trackpad only — never steal finger drags from iPad controls.
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        shouldCaptureScrollForExternal && event.type == .scroll
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Own wheel/trackpad: other pans (SwiftUI ScrollView) must wait / fail.
        gestureRecognizer === scrollPan && shouldCaptureScrollForExternal
    }

    // MARK: - Pointer style (never hide during web fullscreen)

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        // Fullscreen must remain pointer-capable — no UIPointerStyle.hidden().
        shouldSuppressSystemCursor ? .hidden() : nil
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        regionFor request: UIPointerRegionRequest,
        defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        guard shouldSuppressSystemCursor else { return defaultRegion }
        return UIPointerRegion(rect: view.bounds.insetBy(dx: -2000, dy: -2000), identifier: "ipad-pointer-lock")
    }
}
