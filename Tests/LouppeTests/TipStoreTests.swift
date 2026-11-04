#if APP_STORE
import XCTest
@testable import Louppe

@MainActor
final class TipStoreTests: XCTestCase {
    private let tip = TipOption(id: TipOption.productIDs[0], displayName: "Small Tip", displayPrice: "€2.49")

    func testCatalogKeepsApplePricesAndKnownProductOrder() async {
        let client = FakeTipClient()
        client.options = [TipOption(id: "unrelated", displayName: "Other", displayPrice: "$99"), tip]
        let store = TipStore(client: client)
        await store.load()
        XCTAssertEqual(store.catalog, .ready([tip]))
        XCTAssertEqual(client.purchaseCount, 0)
    }

    func testEmptyAndFailedCatalogCanRetryWithoutBuying() async {
        let client = FakeTipClient()
        let store = TipStore(client: client)
        await store.load()
        guard case .failed = store.catalog else { return XCTFail("Empty catalog must be unavailable") }
        client.shouldFail = true
        await store.load()
        guard case .failed = store.catalog else { return XCTFail("Network failure must be visible") }
        client.shouldFail = false
        client.options = [tip]
        await store.load()
        XCTAssertEqual(store.catalog, .ready([tip]))
        XCTAssertEqual(client.purchaseCount, 0)
    }

    func testCancellationPendingApprovalAndFailureNeverThankTheUser() async {
        let client = FakeTipClient()
        client.options = [tip]
        let store = TipStore(client: client)
        await store.load()
        client.result = .cancelled
        await store.purchase(tip)
        XCTAssertEqual(store.purchaseState, .idle)
        client.result = .pending
        await store.purchase(tip)
        XCTAssertEqual(store.purchaseState, .pending)
        let countBeforePendingRetry = client.purchaseCount
        await store.purchase(tip)
        XCTAssertEqual(client.purchaseCount, countBeforePendingRetry)
        client.receive?(.completed)
        XCTAssertEqual(store.purchaseState, .completed)
        client.shouldFail = true
        await store.purchase(tip)
        guard case .failed = store.purchaseState else { return XCTFail("Payment failure must be visible") }
    }

    func testCompletedTipsAreRepeatableButUnknownProductsAreNotPurchased() async {
        let client = FakeTipClient()
        client.options = [tip]
        let store = TipStore(client: client)
        await store.load()
        await store.purchase(tip)
        await store.purchase(tip)
        XCTAssertEqual(store.purchaseState, .completed)
        XCTAssertEqual(client.purchaseCount, 2)
        await store.purchase(TipOption(id: "unknown", displayName: "Other", displayPrice: "$99"))
        XCTAssertEqual(client.purchaseCount, 2)
    }

    func testSecondClickCannotStartAnotherPaymentWhileAppleIsPresenting() async {
        let client = FakeTipClient()
        client.options = [tip]
        let store = TipStore(client: client)
        await store.load()
        client.beforePurchaseReturns = { await store.purchase(self.tip) }
        await store.purchase(tip)
        XCTAssertEqual(client.purchaseCount, 1)
        XCTAssertEqual(store.purchaseState, .completed)
    }
}

@MainActor
private final class FakeTipClient: TipPaymentClient {
    var options: [TipOption] = []
    var result: TipPurchaseResult = .completed
    var shouldFail = false
    var purchaseCount = 0
    var beforePurchaseReturns: (() async -> Void)?
    var receive: (@MainActor (TipPurchaseResult) -> Void)?

    func products() async throws -> [TipOption] {
        if shouldFail { throw NSError(domain: "TipTest", code: 1) }
        return options
    }

    func purchase(productID: String) async throws -> TipPurchaseResult {
        purchaseCount += 1
        if shouldFail { throw NSError(domain: "TipTest", code: 2) }
        await beforePurchaseReturns?()
        return result
    }

    func observeTransactions(_ receive: @escaping @MainActor (TipPurchaseResult) -> Void) {
        self.receive = receive
    }
}
#endif
