import UIKit

class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Native panel size, no TV overscan letterboxing from UIKit.
        windowScene.screen.overscanCompensation = .none

        let viewController = ExternalDisplayViewController()

        // Plain UIWindow on the NonInteractive external scene.
        // Do NOT makeKey — the iPad application window must stay key for pointer/hover.
        // WebKit element-fullscreen windows are created on this same NonInteractive scene;
        // system cursor cannot enter it (use GCMouse + software cursor).
        let window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.coordinateSpace.bounds
        window.rootViewController = viewController
        window.backgroundColor = .black
        window.isUserInteractionEnabled = true
        self.window = window
        window.isHidden = false

        print("[FSWeb] external scene connected role=\(String(describing: session.role)) bounds=\(window.frame)")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Visible only — never steal key from the interactive application window.
        window?.isHidden = false
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        WebViewStore.shared.detach()
        window = nil
    }
}
