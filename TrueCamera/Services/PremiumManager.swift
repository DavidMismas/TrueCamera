import Combine
import Foundation
import StoreKit

@MainActor
final class PremiumManager: ObservableObject {
    enum LockedFeature {
        case all
        case fullResolution
        case unlimitedPresets

        var title: String {
            switch self {
            case .all:
                return "Grejn Pro"
            case .fullResolution:
                return "Unlock Full Resolution"
            case .unlimitedPresets:
                return "Unlock Unlimited Presets"
            }
        }

        var subtitle: String {
            switch self {
            case .all:
                return "Unlock the complete Pro workflow for Grejn."
            case .fullResolution:
                return "Capture at full resolution instead of the free 12 MP limit."
            case .unlimitedPresets:
                return "Save and manage more than one custom preset."
            }
        }

        var highlights: [String] {
            switch self {
            case .all:
                return [
                    "Full-resolution Apple ProRAW capture",
                    "Unlimited custom preset saves",
                    "One-time purchase with restore support"
                ]
            case .fullResolution:
                return [
                    "Full-resolution Apple ProRAW capture",
                    "Keeps the free 12 MP option available too",
                    "Included in the Grejn Pro unlock"
                ]
            case .unlimitedPresets:
                return [
                    "Save more than one custom preset",
                    "Keep different looks ready for different shoots",
                    "Included in the Grejn Pro unlock"
                ]
            }
        }
    }

    enum PurchaseError: LocalizedError {
        case failedVerification

        var errorDescription: String? {
            switch self {
            case .failedVerification:
                return "The purchase could not be verified."
            }
        }
    }

    @Published private(set) var hasPremiumAccess = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false
    @Published var paywallFeature: LockedFeature = .all
    @Published var isPaywallPresented = false
    @Published var errorMessage: String?

    private var bootstrapTask: Task<Void, Never>?
    private var transactionUpdatesTask: Task<Void, Never>?

    init(startLiveTasks: Bool = true) {
        hasPremiumAccess = PremiumAccessStore.readIsPremiumUnlocked()

        guard startLiveTasks else { return }

        transactionUpdatesTask = Task { [weak self] in
            guard let self else { return }
            await self.observeTransactionUpdates()
        }

        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.bootstrap()
        }
    }

    deinit {
        bootstrapTask?.cancel()
        transactionUpdatesTask?.cancel()
    }

    func presentPaywall(for feature: LockedFeature = .all) {
        paywallFeature = feature
        isPaywallPresented = true
    }

    func loadProductsIfNeeded() async {
        guard products.isEmpty else { return }
        await loadProducts(forceReload: false, maxAttempts: 8, delaySeconds: 2)
    }

    func loadProducts(forceReload: Bool) async {
        await loadProducts(forceReload: forceReload, maxAttempts: 3, delaySeconds: 1)
    }

    private func loadProducts(forceReload: Bool, maxAttempts: Int, delaySeconds: Double) async {
        if isLoadingProducts { return }
        if !forceReload, !products.isEmpty { return }

        isLoadingProducts = true
        defer { isLoadingProducts = false }
        errorMessage = nil

        for attempt in 0 ..< max(1, maxAttempts) {
            do {
                let fetched = try await Product.products(for: PremiumStoreConfig.productIDs)
                    .sorted(by: Self.sortProducts)

                if !fetched.isEmpty {
                    products = fetched
                    errorMessage = nil
                    return
                }
            } catch {
                if attempt == maxAttempts - 1 {
                    errorMessage = "Products are temporarily unavailable. Please try again."
                }
            }

            guard attempt < maxAttempts - 1 else { break }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }

        if products.isEmpty, errorMessage == nil {
            errorMessage = "The offer is not available right now. Check your connection and try again."
        }
    }

    func purchase(_ product: Product) async {
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlementStatus()
                if hasPremiumAccess {
                    isPaywallPresented = false
                }

            case .pending:
                errorMessage = "Your purchase is pending approval."

            case .userCancelled:
                break

            @unknown default:
                errorMessage = "The purchase did not complete."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlementStatus()
            if !hasPremiumAccess {
                errorMessage = "No previous Grejn Pro purchases were found for this Apple ID."
            }
        } catch {
            errorMessage = "Restore Purchases failed."
        }
    }

    func refreshEntitlementStatus() async {
        var unlocked = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }

            guard PremiumStoreConfig.productIDs.contains(transaction.productID) else {
                continue
            }

            if transaction.revocationDate != nil {
                continue
            }

            if let expirationDate = transaction.expirationDate,
               expirationDate < Date() {
                continue
            }

            unlocked = true
            break
        }

        applyPremiumState(unlocked)
    }

    static func preview(unlocked: Bool) -> PremiumManager {
        let manager = PremiumManager(startLiveTasks: false)
        manager.applyPremiumState(unlocked, persist: false)
        return manager
    }

    private func bootstrap() async {
        await loadProducts(forceReload: false)
        await refreshEntitlementStatus()
    }

    private func observeTransactionUpdates() async {
        for await result in Transaction.updates {
            if case .verified(let transaction) = result {
                await transaction.finish()
            }
            await refreshEntitlementStatus()
        }
    }

    private func applyPremiumState(_ unlocked: Bool, persist: Bool = true) {
        hasPremiumAccess = unlocked

        guard persist else { return }
        PremiumAccessStore.write(isPremiumUnlocked: unlocked)
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw PurchaseError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    private static func sortProducts(_ lhs: Product, _ rhs: Product) -> Bool {
        if lhs.price != rhs.price {
            return lhs.price < rhs.price
        }

        return lhs.id < rhs.id
    }
}

enum PremiumStoreConfig {
    static let proLifetimeProductID = "com.david.TrueCamera.pro.lifetime"
    static let productIDs: [String] = [
        proLifetimeProductID
    ]
}
