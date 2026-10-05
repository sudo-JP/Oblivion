//
//  SceneDelegate.swift
//  Oblivion
//
//  Created by Jason Phan on 2026-10-03.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var pendingImportURL: URL?


    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard let _ = (scene as? UIWindowScene) else { return }
        pendingImportURL = connectionOptions.urlContexts.first?.url
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
        presentPendingImport()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else {
            print("No file URL was supplied to the scene.")
            return
        }
        guard pendingImportURL == nil else {
            print("Cannot accept another file while an import is waiting to be presented.")
            return
        }
        pendingImportURL = url
        presentPendingImport()
    }

    func presentPendingImport() {
        guard let url = pendingImportURL else { return }
        guard window?.windowScene?.activationState == .foregroundActive else { return }
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else {
            print("Cannot import this file: only PDF files are currently supported.")
            pendingImportURL = nil
            return
        }
        guard let navigation = window?.rootViewController as? UINavigationController,
              let browser = navigation.viewControllers.first as? ViewController else {
            print("Cannot present import: the file browser is unavailable.")
            return
        }
        if browser.showImport(for: url) {
            pendingImportURL = nil
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }


}
