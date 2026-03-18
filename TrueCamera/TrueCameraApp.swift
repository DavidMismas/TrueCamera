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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var premiumManager = PremiumManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(premiumManager)
                .preferredColorScheme(.dark)
                .onAppear {
                    updateIdleTimer(for: scenePhase)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    updateIdleTimer(for: newPhase)
                }
        }
    }

    private func updateIdleTimer(for phase: ScenePhase) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = (phase == .active)
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
