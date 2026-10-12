#if APP_STORE
import SwiftUI

struct TipView: View {
    static let windowID = "support-louppe"
    @ObservedObject var store: TipStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Support Louppe"))
                .font(.title2.bold())
            Text(L10n.text("Louppe is always free and open source. Tips are optional."))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Help Alex keep developing Louppe. Tips are optional, one-time purchases and do not unlock features."))
                .fixedSize(horizontal: false, vertical: true)

            switch store.catalog {
            case .idle, .loading:
                ProgressView(L10n.text("Loading tips…"))
            case .failed(let message):
                Text(L10n.text("Couldn’t load tips."))
                Text(message).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("Retry")) { Task { await store.load() } }
            case .ready(let options):
                VStack(spacing: 8) {
                    ForEach(options) { option in
                        Button {
                            Task { await store.purchase(option) }
                        } label: {
                            HStack {
                                Text(option.displayName)
                                Spacer()
                                Text(option.displayPrice)
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(store.purchaseState == .purchasing || store.purchaseState == .pending)
                    }
                }
            }

            switch store.purchaseState {
            case .idle: EmptyView()
            case .purchasing: ProgressView(L10n.text("Waiting for Apple…"))
            case .pending:
                Text(L10n.text("Your tip is awaiting approval. Apple will complete it after approval."))
                    .foregroundStyle(.secondary)
            case .completed:
                Text(L10n.text("Thank you for supporting Louppe!"))
            case .failed(let message):
                Text(L10n.text("Couldn’t complete the tip. \(message)"))
            }

            Link(L10n.text("Contact Alex"), destination: URL(string: "mailto:a@alex-markin.com")!)
                .font(.callout)
        }
        .padding(24)
        .frame(width: 380, alignment: .leading)
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
        .task { await store.load() }
    }
}
#endif
