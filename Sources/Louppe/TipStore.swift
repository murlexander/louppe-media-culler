#if APP_STORE
import Combine
import StoreKit

struct TipOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let displayPrice: String

    static let productIDs = ["small", "medium", "large"].map {
        "com.alexandermarkin.louppe.tip.\($0)"
    }
}

enum TipPurchaseResult {
    case completed, pending, cancelled
}

@MainActor
protocol TipPaymentClient: AnyObject {
    func products() async throws -> [TipOption]
    func purchase(productID: String) async throws -> TipPurchaseResult
    func observeTransactions(_ receive: @escaping @MainActor (TipPurchaseResult) -> Void)
}

@MainActor
final class TipStore: ObservableObject {
    enum CatalogState: Equatable {
        case idle, loading, ready([TipOption]), failed(String)
    }

    enum PurchaseState: Equatable {
        case idle, purchasing, pending, completed, failed(String)
    }

    @Published private(set) var catalog: CatalogState = .idle
    @Published private(set) var purchaseState: PurchaseState = .idle
    private let client: any TipPaymentClient

    init(client: any TipPaymentClient = StoreKitTipClient()) {
        self.client = client
        // Listen from launch, including approvals received after closing the
        // tip window. The client also drains unfinished verified transactions.
        client.observeTransactions { [weak self] result in
            self?.receive(result)
        }
    }

    func load() async {
        guard catalog != .loading else { return }
        catalog = .loading
        do {
            let products = try await client.products()
            let options = TipOption.productIDs.compactMap { id in
                products.first { $0.id == id }
            }
            catalog = options.isEmpty
                ? .failed(L10n.text("Tips are unavailable right now. Try again later."))
                : .ready(options)
        } catch {
            catalog = .failed(error.localizedDescription)
        }
    }

    func purchase(_ option: TipOption) async {
        guard purchaseState != .purchasing, purchaseState != .pending,
              case .ready(let options) = catalog,
              options.contains(option) else { return }
        purchaseState = .purchasing
        do {
            receive(try await client.purchase(productID: option.id))
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    private func receive(_ result: TipPurchaseResult) {
        switch result {
        case .completed: purchaseState = .completed
        case .pending: purchaseState = .pending
        case .cancelled: purchaseState = .idle
        }
    }
}

private enum TipPaymentError: LocalizedError {
    case unavailable, unverified

    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.text("Tips are unavailable right now. Try again later.")
        case .unverified: L10n.text("Apple could not verify the tip. Contact Alex if you were charged.")
        }
    }
}

@MainActor
private final class StoreKitTipClient: TipPaymentClient {
    private var availableProducts: [Product] = []
    private var updatesTask: Task<Void, Never>?
    private var unfinishedTask: Task<Void, Never>?

    deinit {
        updatesTask?.cancel()
        unfinishedTask?.cancel()
    }

    func products() async throws -> [TipOption] {
        guard AppStore.canMakePayments else { throw TipPaymentError.unavailable }
        availableProducts = try await Product.products(for: TipOption.productIDs)
            .filter { $0.type == .consumable }
        return availableProducts.map {
            TipOption(id: $0.id, displayName: $0.displayName, displayPrice: $0.displayPrice)
        }
    }

    func purchase(productID: String) async throws -> TipPurchaseResult {
        guard let product = availableProducts.first(where: { $0.id == productID }),
              AppStore.canMakePayments else { throw TipPaymentError.unavailable }
        switch try await product.purchase() {
        case .success(let verification):
            guard await complete(verification) else { throw TipPaymentError.unverified }
            return .completed
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw TipPaymentError.unavailable
        }
    }

    func observeTransactions(_ receive: @escaping @MainActor (TipPurchaseResult) -> Void) {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await verification in StoreKit.Transaction.updates {
                guard !Task.isCancelled, let self else { return }
                if await self.complete(verification) { receive(.completed) }
            }
        }
        unfinishedTask = Task { [weak self] in
            for await verification in StoreKit.Transaction.unfinished {
                guard !Task.isCancelled, let self else { return }
                if await self.complete(verification) { receive(.completed) }
            }
        }
    }

    private func complete(_ verification: VerificationResult<StoreKit.Transaction>) async -> Bool {
        guard case .verified(let transaction) = verification,
              TipOption.productIDs.contains(transaction.productID),
              transaction.productType == .consumable,
              transaction.revocationDate == nil else { return false }
        // Tips grant no entitlement and keep no balance. Verification is the
        // entire delivery step; finish only our verified consumable tips.
        await transaction.finish()
        return true
    }
}
#endif
