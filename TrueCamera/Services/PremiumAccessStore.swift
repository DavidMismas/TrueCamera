import Foundation

enum PremiumAccessStore {
    private static let premiumUnlockedKey = "premium.truecamera.unlocked"
    #if DEBUG
    private static let debugBuildHasPremiumAccess = true
    #endif

    static func write(isPremiumUnlocked: Bool) {
        UserDefaults.standard.set(isPremiumUnlocked, forKey: premiumUnlockedKey)
    }

    static func readIsPremiumUnlocked() -> Bool {
        #if DEBUG
        if debugBuildHasPremiumAccess {
            return true
        }
        #endif
        return UserDefaults.standard.bool(forKey: premiumUnlockedKey)
    }
}
