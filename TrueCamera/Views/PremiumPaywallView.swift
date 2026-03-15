import StoreKit
import SwiftUI

struct PremiumPaywallView: View {
    @EnvironmentObject private var premiumManager: PremiumManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    featureList
                    purchaseSection
                    restoreSection
                }
                .padding()
            }
            .navigationTitle("Grejn Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .task {
                await premiumManager.loadProductsIfNeeded()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active,
                      premiumManager.products.isEmpty,
                      !premiumManager.isLoadingProducts else {
                    return
                }

                Task {
                    await premiumManager.loadProducts(forceReload: true)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(premiumManager.paywallFeature.title)
                .font(.headline)

            if premiumManager.hasPremiumAccess {
                Text("Grejn Pro is already unlocked on this device.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Text(premiumManager.paywallFeature.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = premiumManager.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Pro unlocks")
                .font(.headline)

            ForEach(premiumManager.paywallFeature.highlights, id: \.self) { item in
                featureRow(item)
            }
        }
    }

    private var purchaseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Purchase")
                .font(.headline)

            if premiumManager.isLoadingProducts {
                ProgressView("Loading offers...")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if premiumManager.products.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The App Store offer is still loading. If it does not appear automatically, try again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Try Again") {
                        Task {
                            await premiumManager.loadProducts(forceReload: true)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ForEach(premiumManager.products, id: \.id) { product in
                    Button {
                        Task {
                            await premiumManager.purchase(product)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(product.displayName)
                                        .font(.headline.weight(.semibold))
                                    Text(product.description)
                                        .font(.caption)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                Text(product.displayPrice)
                                    .font(.title3.weight(.bold))
                            }

                            HStack(spacing: 6) {
                                Text("Unlock Pro")
                                    .font(.subheadline.weight(.semibold))
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.subheadline)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.08, green: 0.70, blue: 0.66), Color(red: 0.06, green: 0.46, blue: 0.56)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(premiumManager.isPurchasing)
                }
            }
        }
    }

    private var restoreSection: some View {
        HStack {
            Button("Restore Purchases") {
                Task {
                    await premiumManager.restorePurchases()
                }
            }
            .buttonStyle(.bordered)
            .disabled(premiumManager.isPurchasing)

            Spacer()

            if premiumManager.isPurchasing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func featureRow(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(title)
                .font(.subheadline)
        }
    }
}

#Preview {
    PremiumPaywallView()
        .environmentObject(PremiumManager.preview(unlocked: false))
}
