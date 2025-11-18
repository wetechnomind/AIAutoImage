//
//  SceneDelegate.swift
//  AIAutoImageDemo
//

import UIKit

/// The scene delegate manages the lifecycle of a UI scene.
///
/// In multi-window environments (iPadOS, macOS via Catalyst), each window
/// uses its own `SceneDelegate` to configure UI, display view controllers,
/// and respond to scene-level events.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// The primary window displayed for this scene.
    ///
    /// UIKit creates one window per scene, and this property retains
    /// a strong reference to ensure it stays active for the lifetime of the scene.
    var window: UIWindow?

    /// Called when the system connects a scene to the app.
    ///
    /// Use this function to configure and attach the window and root view controller.
    /// This is the UIKit equivalent of SwiftUI's `@main App` bootstrap.
    ///
    /// - Parameters:
    ///   - scene: The scene instance provided by the system.
    ///   - session: The session associated with this scene.
    ///   - connectionOptions: Information about how the scene was launched.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // Ensure the incoming scene can host UIKit windows
        guard let windowScene = scene as? UIWindowScene else { return }

        /// Create the main window attached to this scene
        let window = UIWindow(windowScene: windowScene)

        /// Set the initial UI — a navigation controller with the gallery screen
        window.rootViewController = UINavigationController(
            rootViewController: GalleryViewController()
        )

        /// Make the window key & visible
        window.makeKeyAndVisible()

        /// Assign to property to retain the window
        self.window = window
    }
}
