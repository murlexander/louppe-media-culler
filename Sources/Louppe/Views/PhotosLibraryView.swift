import SwiftUI

struct PhotosLibraryView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var browser: PhotosLibraryBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var useDates = false
    @State private var from = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var through = Date()

    var body: some View {
        SheetForm(title: L10n.text("Apple Photos"), layout: browser.isOpening ? .scrolling : .grouped) {
            if browser.isOpening {
                loading
            } else {
                if let failure = browser.failure {
                    Section {
                        Text(failure.message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        if failure.isSelectionFailure {
                            Button(L10n.text("Retry")) { Task { await browser.load() } }
                        }
                    }
                }
                selection
            }
        } actions: {
            HStack(spacing: 12) {
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) {
                    if browser.isOpening { store.cancelPhotosOpening() }
                    else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                if !browser.isOpening {
                    Button(browser.failure?.requiresDownload == true
                           ? L10n.text("Download and Open Batch") : L10n.text("Open Batch")) {
                        if browser.failure?.requiresDownload == true { browser.allowNetwork = true }
                        store.openPhotosBatch(page: browser.page)
                    }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(browser.isLoading || browser.snapshot?.count == nil || browser.range.total == 0)
                }
            }
        }
        .frame(width: 540, height: 560)
        .interactiveDismissDisabled(browser.isOpening)
        .task { if !browser.isOpening { await browser.load() } }
        .onAppear {
            useDates = browser.query.startDate != nil
            from = browser.query.startDate ?? from
            if let end = browser.query.endDate { through = end.addingTimeInterval(-1) }
        }
        .onChange(of: browser.query) { _, _ in
            guard !browser.isOpening, browser.snapshot?.query != browser.query else { return }
            browser.page = 0
            Task { await browser.load() }
        }
    }

    private var selection: some View {
        Group {
            Section {
                Picker(L10n.text("Source"), selection: $browser.query.albumID) {
                    Text(L10n.text("All Photos and Videos")).tag(String?.none)
                    ForEach(browser.albums) { album in Text(album.title).tag(Optional(album.id)) }
                }
                .disabled(browser.isLoading)
                Picker(L10n.text("Order"), selection: $browser.query.newestFirst) {
                    Text(L10n.text("Newest first")).tag(true)
                    Text(L10n.text("Oldest first")).tag(false)
                }
            }
            Section {
                Toggle(L10n.text("Date range"), isOn: $useDates)
                    .onChange(of: useDates) { _, _ in updateDates() }
                Menu(L10n.text("Recent Dates")) {
                    ForEach(PhotosRecentDateRange.allCases, id: \.self) { range in
                        Button(range.title) { applyRecentDates(range) }
                    }
                }
                if useDates {
                    DatePicker(L10n.text("From"), selection: $from, in: ...through, displayedComponents: .date)
                        .onChange(of: from) { _, _ in updateDates() }
                    DatePicker(L10n.text("Through"), selection: $through, in: from..., displayedComponents: .date)
                        .onChange(of: through) { _, _ in updateDates() }
                }
            }
            Section {
                Picker(L10n.text("Batch size"), selection: Binding(
                    get: { browser.batchSize },
                    set: { browser.batchSize = $0; browser.page = 0; browser.remember() }
                )) {
                    ForEach(PhotosBatchRange.sizes, id: \.self) { size in Text(size.formatted()).tag(size) }
                }
                if browser.range.pageCount > 0 {
                    LabeledContent(L10n.text("Batch")) {
                        HStack(spacing: 6) {
                            TextField("", value: Binding(
                                get: { browser.range.page + 1 },
                                set: { browser.page = min(max(1, $0), browser.range.pageCount) - 1 }
                            ), format: .number.grouping(.never))
                            .frame(width: 56)
                            .accessibilityLabel(L10n.text("Batch \((browser.range.page + 1).formatted()) of \(browser.range.pageCount.formatted())"))
                            Text(verbatim: "/ \(browser.range.pageCount.formatted())")
                            Stepper("", value: $browser.page, in: 0...(browser.range.pageCount - 1))
                                .labelsHidden()
                                .accessibilityLabel(L10n.text("Batch"))
                        }
                    }
                }
            } footer: {
                if browser.isLoading {
                    HStack { ProgressView().controlSize(.small); Text(L10n.text("Reading Photos selection…")) }
                } else if let snapshot = browser.snapshot {
                    Text(L10n.text("\(snapshot.count.formatted()) items match this selection."))
                }
            }
            Section {
                Toggle(L10n.text("Allow iCloud Review Images"), isOn: $browser.allowNetwork)
            } footer: {
                Text(L10n.text("Review images load as you browse. Photos may download source data to make a preview. Originals are requested separately for original detail and Copy. Decisions save in Louppe; your library stays unchanged. Live Photos use their still image."))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = browser.progress {
                ProgressView(value: Double(progress.completed) + progress.downloadFraction,
                             total: Double(max(1, progress.total)))
                .accessibilityLabel(L10n.text("Preparing \(progress.completed.formatted()) of \(progress.total.formatted()) items…"))
                Text(L10n.text("Preparing \(progress.completed.formatted()) of \(progress.total.formatted()) items…"))
            } else {
                ProgressView().controlSize(.small)
                Text(L10n.text("Saving decisions before opening Photos…"))
            }
            Text(L10n.text("Opening the selection does not download its originals."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func updateDates() {
        guard !browser.isOpening else { return }
        var query = browser.query
        query.startDate = useDates ? Calendar.current.startOfDay(for: from) : nil
        query.endDate = useDates
            ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: through))
            : nil
        browser.query = query
    }

    private func applyRecentDates(_ range: PhotosRecentDateRange) {
        guard let interval = range.interval() else { return }
        from = interval.start
        through = interval.end.addingTimeInterval(-1)
        useDates = true
        updateDates()
    }
}

struct PhotosBatchBar: View {
    @ObservedObject var store: SessionStore
    @Environment(\.layoutDirection) private var layoutDirection
    let batch: PhotosReviewBatch
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("Apple Photos · \((batch.range.start + 1).formatted())–\(batch.range.end.formatted()) of \(batch.range.total.formatted())"))
                    .font(.callout)
                Text(batch.mediaSession == nil ? L10n.text("Decisions saved in Louppe")
                     : L10n.text("Preview review · decisions saved in Louppe"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Toggle(L10n.text("Allow iCloud Review Images"), isOn: $store.photosReviewNetwork)
                Toggle(L10n.text("Allow iCloud Originals"), isOn: $store.photosOriginalNetwork)
                Text(L10n.text("Photos may download source data to make a review image."))
            } label: { Label(L10n.text("iCloud Access"), systemImage: "icloud") }
            .fixedSize()
            Button(L10n.text("Choose Photos…")) { store.presentPhotosLibrary() }
                .fixedSize()
            Button { store.openPhotosBatch(page: batch.range.page - 1, continuing: true) } label: {
                Label(L10n.text("Previous Batch"), systemImage: layoutDirection == .rightToLeft ? "chevron.right" : "chevron.left")
            }
            .fixedSize()
            .disabled(!batch.range.hasPrevious)
            Button { store.openPhotosBatch(page: batch.range.page + 1, continuing: true) } label: {
                Label(L10n.text("Next Batch"), systemImage: layoutDirection == .rightToLeft ? "chevron.left" : "chevron.right")
            }
            .fixedSize()
            .disabled(!batch.range.hasNext)
        }
        .disabled(store.isFileOperationRunning || store.isSessionCommandPresentationActive)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.appBackground)
        .overlay(alignment: .bottom) { Divider() }
    }
}
