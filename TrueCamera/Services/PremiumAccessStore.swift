import Foundation

enum PremiumAccessStore {
    private static let premiumUnlockedKey = "premium.truecamera.unlocked"

    static func write(isPremiumUnlocked: Bool) {
        UserDefaults.standard.set(isPremiumUnlocked, forKey: premiumUnlockedKey)
    }

    static func readIsPremiumUnlocked() -> Bool {
        UserDefaults.standard.bool(forKey: premiumUnlockedKey)
    }
}
