//
//  FullScreenWebApp.swift
//  FullScreenWeb
//
//  Created by Yaroslav Mostovoy on 29.08.2026.
//

import SwiftUI

@main
struct FullScreenWebApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
