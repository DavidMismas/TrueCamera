//
//  TrueCameraApp.swift
//  TrueCamera
//
//  Created by David Mišmaš on 19. 2. 2026.
//

import SwiftUI
import UIKit

@main
struct TrueCameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var premiumManager = PremiumManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(premiumManager)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }
}
