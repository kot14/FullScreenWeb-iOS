import AVFoundation
import Combine
import UIKit
import WebKit

final class ExternalDisplayViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate {
    private let store = WebViewStore.shared
    private let pointer = ExternalPointerController()
    private let bridgeHandler = WebFramePointerBridgeHandler()

    /// Full-screen picture that is scaled/offset for display overscan (розгортка).
    private let displayCanvas = UIView()
    private let chromeStack = UIStackView()
    private let urlField = UITextField()
    private let webView: WKWebView
    private let showChromeButton = UIButton(type: .system)
    private weak var addShortcutButton: UIButton?
    private weak var goButton: UIButton?

    private var chromeHeightConstraint: NSLayoutConstraint?
    private var chromeIconHeightConstraints: [NSLayoutConstraint] = []
    private var cancellables = Set<AnyCancellable>()
    private var fullscreenObservation: NSKeyValueObservation?

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true

        let webpage = WKWebpagePreferences()
        webpage.allowsContentJavaScript = true
        webpage.preferredContentMode = .desktop
        config.defaultWebpagePreferences = webpage

        // Inject into main frame AND iframes. Cross-origin video is played inside its frame
        // via postMessage; never read iframe DOM from the parent.
        config.userContentController.add(bridgeHandler, name: WebFramePointerBridge.messageName)
        config.userContentController.addUserScript(
            WKUserScript(
                source: WebFramePointerBridge.userScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        bridgeHandler.webView = webView
        super.init(nibName: nil, bundle: nil)

        if store.isAdBlockEnabled {
            AdBlocker.install(on: webView.configuration.userContentController) { [weak self] success in
                // First navigation may start before rules finish compiling — reload once ready.
                guard success, let self, self.webView.url != nil else { return }
                self.webView.reload()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

        activatePlaybackAudioSession()

        setupCanvas()
        setupChrome()
        setupWebView()
        setupShowChromeButton()
        bindStore()

        store.attach(webView: webView, canvas: displayCanvas)
        urlField.text = store.currentURLString

        pointer.attach(
            hostView: view,
            canvasView: displayCanvas,
            webView: webView,
            urlField: urlField
        )
        pointer.onURLSubmit = { [weak self] in
            self?.submitURL()
        }

        // Observe after the view is in a window — `.initial` in viewDidLoad sees window=nil.
        fullscreenObservation = webView.observe(\.fullscreenState, options: [.new]) { [weak self] webView, _ in
            self?.pointer.handleFullscreenStateChanged(webView)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Now hostView / webView have a real UIWindow (external NonInteractive scene).
        pointer.handleFullscreenStateChanged(webView)
        pointer.hostDidLayout()
        PointerDiagnostics.logSurface("host after appear", view: view)
        PointerDiagnostics.logSurface("webView after appear", view: webView)
    }

    private func activatePlaybackAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // Non-fatal: video may still render without audio routing tweaks.
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        store.applyDisplayTransform()
        pointer.hostDidLayout()
    }

    deinit {
        fullscreenObservation?.invalidate()
        WebViewStore.shared.isWebFullscreen = false
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: WebFramePointerBridge.messageName
        )
        pointer.detach()
    }

    // MARK: - Setup

    private func setupCanvas() {
        displayCanvas.backgroundColor = .black
        displayCanvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(displayCanvas)

        NSLayoutConstraint.activate([
            displayCanvas.topAnchor.constraint(equalTo: view.topAnchor),
            displayCanvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            displayCanvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            displayCanvas.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupChrome() {
        chromeStack.axis = .horizontal
        chromeStack.alignment = .center
        chromeStack.spacing = 8
        chromeStack.isLayoutMarginsRelativeArrangement = true
        chromeStack.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        chromeStack.backgroundColor = UIColor(white: 0.12, alpha: 0.94)
        chromeStack.translatesAutoresizingMaskIntoConstraints = false
        displayCanvas.addSubview(chromeStack)

        let back = makeIconButton(systemName: "chevron.left", action: #selector(goBack))
        let forward = makeIconButton(systemName: "chevron.right", action: #selector(goForward))
        let reload = makeIconButton(systemName: "arrow.clockwise", action: #selector(reload))
        let addShortcut = makeIconButton(systemName: "star", action: #selector(addToQuickAccess))
        addShortcutButton = addShortcut
        let hide = makeIconButton(systemName: "chevron.up", action: #selector(hideChrome))

        urlField.borderStyle = .roundedRect
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.keyboardType = .URL
        urlField.returnKeyType = .go
        urlField.clearButtonMode = .whileEditing
        urlField.delegate = self
        urlField.font = .systemFont(ofSize: 16)
        // White field on dark chrome: force light appearance so text isn't white-on-white
        // when the external scene inherits dark mode.
        urlField.overrideUserInterfaceStyle = .light
        urlField.backgroundColor = .white
        urlField.textColor = .black
        urlField.tintColor = .systemBlue
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let go = UIButton(type: .system)
        go.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        go.addTarget(self, action: #selector(submitURL), for: .touchUpInside)
        go.setContentHuggingPriority(.required, for: .horizontal)
        goButton = go

        [back, forward, reload, urlField, go, addShortcut, hide].forEach { chromeStack.addArrangedSubview($0) }
        applyLocalizedChromeStrings()

        let height = chromeStack.heightAnchor.constraint(equalToConstant: 56)
        chromeHeightConstraint = height

        NSLayoutConstraint.activate([
            chromeStack.topAnchor.constraint(equalTo: displayCanvas.safeAreaLayoutGuide.topAnchor),
            chromeStack.leadingAnchor.constraint(equalTo: displayCanvas.leadingAnchor),
            chromeStack.trailingAnchor.constraint(equalTo: displayCanvas.trailingAnchor),
            height
        ])
    }

    private func setupWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .black
        webView.isOpaque = true
        // Layout at native canvas size — stretch is applied to the whole display canvas.
        displayCanvas.insertSubview(webView, at: 0)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: chromeStack.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: displayCanvas.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: displayCanvas.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: displayCanvas.bottomAnchor)
        ])
    }

    private func setupShowChromeButton() {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "globe")
        config.baseBackgroundColor = UIColor(white: 0.15, alpha: 0.85)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        showChromeButton.configuration = config
        showChromeButton.isHidden = true
        showChromeButton.translatesAutoresizingMaskIntoConstraints = false
        showChromeButton.addTarget(self, action: #selector(showChrome), for: .touchUpInside)
        displayCanvas.addSubview(showChromeButton)

        NSLayoutConstraint.activate([
            showChromeButton.topAnchor.constraint(equalTo: displayCanvas.safeAreaLayoutGuide.topAnchor, constant: 12),
            showChromeButton.trailingAnchor.constraint(equalTo: displayCanvas.trailingAnchor, constant: -16)
        ])
    }

    private func bindStore() {
        store.$isAddressBarVisible
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateChromeVisibility(animated: true)
            }
            .store(in: &cancellables)

        store.$currentURLString
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                guard let self, !self.urlField.isFirstResponder else { return }
                self.urlField.text = url
                self.updateShortcutButtonAppearance()
            }
            .store(in: &cancellables)

        store.$shortcuts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateShortcutButtonAppearance()
            }
            .store(in: &cancellables)

        LanguageStore.shared.$language
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyLocalizedChromeStrings()
            }
            .store(in: &cancellables)

        updateChromeVisibility(animated: false)
        updateShortcutButtonAppearance()
    }

    private func applyLocalizedChromeStrings() {
        urlField.attributedPlaceholder = NSAttributedString(
            string: L10n.urlPlaceholder,
            attributes: [.foregroundColor: UIColor(white: 0.55, alpha: 1)]
        )
        goButton?.setTitle(L10n.go, for: .normal)
        updateShortcutButtonAppearance()
    }

    private func makeIconButton(systemName: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.tintColor = .white
        button.setContentHuggingPriority(.required, for: .horizontal)
        // Larger hit target — software cursor tip needs forgiving chrome controls.
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let height = button.heightAnchor.constraint(equalToConstant: 44)
        height.isActive = true
        chromeIconHeightConstraints.append(height)
        return button
    }

    // MARK: - Chrome

    private func updateChromeVisibility(animated: Bool) {
        let visible = store.isAddressBarVisible
        let updates = {
            self.chromeStack.alpha = visible ? 1 : 0
            self.chromeStack.isUserInteractionEnabled = visible
            // Avoid UIStackView.height == 0 vs UIButton.height == 36 conflicts:
            // deactivate fixed icon heights and hide arranged children when collapsed.
            self.chromeIconHeightConstraints.forEach { $0.isActive = visible }
            self.chromeStack.arrangedSubviews.forEach { $0.isHidden = !visible }
            self.chromeHeightConstraint?.constant = visible ? 56 : 0
            self.showChromeButton.isHidden = visible
            self.displayCanvas.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: updates)
        } else {
            updates()
        }
    }

    @objc private func hideChrome() {
        store.isAddressBarVisible = false
        urlField.resignFirstResponder()
    }

    @objc private func showChrome() {
        store.isAddressBarVisible = true
    }

    // MARK: - Actions

    @objc private func goBack() { store.goBack() }
    @objc private func goForward() { store.goForward() }
    @objc private func reload() { store.reload() }

    @objc private func addToQuickAccess() {
        _ = store.toggleCurrentPageInShortcuts()
        updateShortcutButtonAppearance()
    }

    private func updateShortcutButtonAppearance() {
        guard let button = addShortcutButton else { return }
        let isSaved = store.isCurrentPageInShortcuts()
        button.setImage(UIImage(systemName: isSaved ? "star.fill" : "star"), for: .normal)
        button.tintColor = isSaved ? .systemYellow : .white
        button.accessibilityLabel = isSaved ? L10n.removeFromQuickAccessA11y : L10n.addToQuickAccessA11y
    }

    @objc private func submitURL() {
        store.load(urlField.text ?? "")
        urlField.resignFirstResponder()
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitURL()
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Keep browsing inside WKWebView: YouTube and others try youtube:// / itms-apps:// etc.
        // Allowing those schemes hands control to the native iPad app.
        let scheme = (url.scheme ?? "").lowercased()
        let allowedSchemes: Set<String> = ["http", "https", "about", "blob", "data", "file"]
        if !allowedSchemes.contains(scheme) {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store.updateCurrentURL(from: webView)
        if !urlField.isFirstResponder {
            urlField.text = webView.url?.absoluteString ?? store.currentURLString
        }
        updateShortcutButtonAppearance()
        if store.isAdBlockEnabled {
            AdBlocker.injectCosmeticCleanup(into: webView)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        store.updateCurrentURL(from: webView)
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // target=_blank / window.open — load in the same view instead of spawning a new one
        // that might escape to the system / YouTube app.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            let scheme = (url.scheme ?? "").lowercased()
            if scheme == "http" || scheme == "https" {
                webView.load(navigationAction.request)
            }
        }
        return nil
    }
}
