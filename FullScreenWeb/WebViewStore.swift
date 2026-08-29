import Foundation
import WebKit
import UIKit

final class WebViewStore: NSObject, ObservableObject {
    static let shared = WebViewStore()

    private enum DefaultsKey {
        static let scaleX = "display.scaleX"
        static let scaleY = "display.scaleY"
        static let offsetX = "display.offsetX"
        static let offsetY = "display.offsetY"
        static let lastURL = "display.lastURL"
        static let adBlockEnabled = "display.adBlockEnabled"
        static let addressBarVisible = "display.addressBarVisible"
        static let shortcuts = "display.shortcuts"
    }

    var externalWebView: WKWebView?
    /// Full-screen canvas on the external display (scaled for panel fit / overscan).
    weak var displayCanvas: UIView?
    private var pendingURLString: String?

    @Published var currentURLString: String
    @Published var shortcuts: [LinkShortcut]
    @Published var isExternalDisplayConnected: Bool = UIScreen.screens.count > 1
    @Published var isAddressBarVisible: Bool {
        didSet {
            UserDefaults.standard.set(isAddressBarVisible, forKey: DefaultsKey.addressBarVisible)
        }
    }
    /// Blocks common ad/tracker network requests via WKContentRuleList.
    @Published var isAdBlockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAdBlockEnabled, forKey: DefaultsKey.adBlockEnabled)
            applyAdBlockPreference()
        }
    }
    /// When true, system mouse pointer is locked/hidden on iPad and drives the external cursor.
    /// While `isWebFullscreen` is true, iPad must NOT hide/lock the pointer (fullscreen stays pointer-capable).
    @Published var captureMouseForExternalDisplay: Bool = true
    /// WKWebView element fullscreen — WebKit moves the web view into its own window.
    @Published var isWebFullscreen: Bool = false

    /// Forwards trackpad/mouse-wheel deltas captured on the iPad scene to the external browser.
    var onExternalScroll: ((CGFloat, CGFloat, Bool) -> Void)?

    func forwardScroll(dx: CGFloat, dy: CGFloat, asPixels: Bool) {
        guard isExternalDisplayConnected, captureMouseForExternalDisplay else { return }
        onExternalScroll?(dx, dy, asPixels)
    }

    @Published var scaleX: CGFloat {
        didSet { persistTransform(); applyDisplayTransform() }
    }
    @Published var scaleY: CGFloat {
        didSet { persistTransform(); applyDisplayTransform() }
    }
    @Published var offsetX: CGFloat {
        didSet { persistTransform(); applyDisplayTransform() }
    }
    @Published var offsetY: CGFloat {
        didSet { persistTransform(); applyDisplayTransform() }
    }

    private override init() {
        let defaults = UserDefaults.standard
        scaleX = Self.clampedScale(Self.cgFloat(defaults, key: DefaultsKey.scaleX, fallback: 1))
        scaleY = Self.clampedScale(Self.cgFloat(defaults, key: DefaultsKey.scaleY, fallback: 1))
        offsetX = Self.clampedOffset(Self.cgFloat(defaults, key: DefaultsKey.offsetX, fallback: 0))
        offsetY = Self.clampedOffset(Self.cgFloat(defaults, key: DefaultsKey.offsetY, fallback: 0))
        currentURLString = defaults.string(forKey: DefaultsKey.lastURL) ?? "https://www.google.com"
        shortcuts = Self.loadShortcuts(from: defaults)
        if defaults.object(forKey: DefaultsKey.addressBarVisible) == nil {
            isAddressBarVisible = true
        } else {
            isAddressBarVisible = defaults.bool(forKey: DefaultsKey.addressBarVisible)
        }
        if defaults.object(forKey: DefaultsKey.adBlockEnabled) == nil {
            isAdBlockEnabled = true
        } else {
            isAdBlockEnabled = defaults.bool(forKey: DefaultsKey.adBlockEnabled)
        }

        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: UIScreen.didConnectNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: UIScreen.didDisconnectNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        DispatchQueue.main.async {
            self.isExternalDisplayConnected = UIScreen.screens.count > 1
        }
    }

    func load(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalized = normalizedURLString(trimmed)
        currentURLString = normalized
        UserDefaults.standard.set(normalized, forKey: DefaultsKey.lastURL)

        guard let url = URL(string: normalized) else { return }
        if let webView = externalWebView {
            // Cancel in-flight navigation / synthetic pointer so shortcuts always win.
            NativeWebPointerInjector.cancel()
            webView.stopLoading()
            webView.load(URLRequest(url: url))
            pendingURLString = nil
        } else {
            pendingURLString = normalized
        }
    }

    func addShortcut(title: String, urlString: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedURL.isEmpty else { return }

        let normalized = normalizedURLString(trimmedURL)
        guard !shortcuts.contains(where: { normalizedURLString($0.urlString) == normalized }) else { return }

        shortcuts.append(LinkShortcut(title: trimmedTitle, urlString: normalized))
        persistShortcuts()
    }

    func isCurrentPageInShortcuts() -> Bool {
        guard let normalized = currentPageNormalizedURL() else { return false }
        return shortcuts.contains { normalizedURLString($0.urlString) == normalized }
    }

    /// Toggles the current external page in quick-access shortcuts.
    @discardableResult
    func toggleCurrentPageInShortcuts() -> Bool? {
        guard let normalized = currentPageNormalizedURL() else { return nil }

        if let existing = shortcuts.first(where: { normalizedURLString($0.urlString) == normalized }) {
            removeShortcut(existing)
            return false
        }

        let pageTitle = externalWebView?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: normalized)?.host
        let title: String
        if let pageTitle, !pageTitle.isEmpty {
            title = pageTitle
        } else if let host, !host.isEmpty {
            title = host
        } else {
            title = L10n.siteFallbackTitle
        }

        shortcuts.append(LinkShortcut(title: title, urlString: normalized))
        persistShortcuts()
        return true
    }

    private func currentPageNormalizedURL() -> String? {
        let rawURL = externalWebView?.url?.absoluteString ?? currentURLString
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return normalizedURLString(trimmed)
    }

    func removeShortcut(_ shortcut: LinkShortcut) {
        shortcuts.removeAll { $0.id == shortcut.id }
        persistShortcuts()
    }

    func attach(webView: WKWebView, canvas: UIView) {
        externalWebView = webView
        displayCanvas = canvas
        applyDisplayTransform()

        let urlString = pendingURLString ?? currentURLString
        pendingURLString = nil
        if let url = URL(string: normalizedURLString(urlString)) {
            webView.load(URLRequest(url: url))
        }
    }

    func detach() {
        externalWebView = nil
        displayCanvas = nil
        onExternalScroll = nil
    }

    func goBack() { externalWebView?.goBack() }
    func goForward() { externalWebView?.goForward() }
    func reload() { externalWebView?.reload() }

    func applyAdBlockPreference() {
        guard let webView = externalWebView else { return }
        let controller = webView.configuration.userContentController
        if isAdBlockEnabled {
            AdBlocker.install(on: controller) { [weak self] success in
                guard success else { return }
                self?.externalWebView?.reload()
            }
        } else {
            AdBlocker.uninstall(from: controller)
            webView.reload()
        }
    }

    func resetTransform() {
        scaleX = 1
        scaleY = 1
        offsetX = 0
        offsetY = 0
    }

    func nudgeScaleX(_ delta: CGFloat) {
        scaleX = Self.clampedScale(scaleX + delta)
    }

    func nudgeScaleY(_ delta: CGFloat) {
        scaleY = Self.clampedScale(scaleY + delta)
    }

    func nudgeOffsetX(_ delta: CGFloat) {
        offsetX = Self.clampedOffset(offsetX + delta)
    }

    func nudgeOffsetY(_ delta: CGFloat) {
        offsetY = Self.clampedOffset(offsetY + delta)
    }

    /// Scales the entire external framebuffer (розгортка), not page layout inside WKWebView.
    func applyDisplayTransform() {
        guard let canvas = displayCanvas else { return }
        canvas.transform = CGAffineTransform(translationX: offsetX, y: offsetY)
            .scaledBy(x: scaleX, y: scaleY)
    }

    func updateCurrentURL(from webView: WKWebView) {
        guard let url = webView.url?.absoluteString else { return }
        DispatchQueue.main.async {
            self.currentURLString = url
            UserDefaults.standard.set(url, forKey: DefaultsKey.lastURL)
        }
    }

    private func persistTransform() {
        let defaults = UserDefaults.standard
        defaults.set(Double(scaleX), forKey: DefaultsKey.scaleX)
        defaults.set(Double(scaleY), forKey: DefaultsKey.scaleY)
        defaults.set(Double(offsetX), forKey: DefaultsKey.offsetX)
        defaults.set(Double(offsetY), forKey: DefaultsKey.offsetY)
    }

    private func persistShortcuts() {
        guard let data = try? JSONEncoder().encode(shortcuts) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.shortcuts)
    }

    private static func loadShortcuts(from defaults: UserDefaults) -> [LinkShortcut] {
        guard let data = defaults.data(forKey: DefaultsKey.shortcuts),
              let saved = try? JSONDecoder().decode([LinkShortcut].self, from: data),
              !saved.isEmpty
        else {
            return LinkShortcut.defaults
        }
        return saved
    }

    private func normalizedURLString(_ s: String) -> String {
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        return "https://\(s)"
    }

    static func clampedScale(_ value: CGFloat) -> CGFloat {
        min(1.5, max(0.7, value))
    }

    static func clampedOffset(_ value: CGFloat) -> CGFloat {
        min(200, max(-200, value))
    }

    private static func cgFloat(_ defaults: UserDefaults, key: String, fallback: CGFloat) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return CGFloat(defaults.double(forKey: key))
    }
}
