import Combine
import Foundation

/// Only a successful inspection may change the sheet's conditional XMP default.
@MainActor
final class ExportXMPInspectionState: ObservableObject {
    typealias Inspector = @Sendable ([PhotoItem], [PhotoItem]) throws -> XMPExportSourceInspection
    enum Status: Equatable {
        case idle
        case checking
        case checked(XMPExportSourceInspection)
        case failed
    }

    @Published private(set) var status: Status = .idle
    @Published var inclusionChoice = ExportXMPInclusionChoice()

    var inspection: XMPExportSourceInspection? {
        if case .checked(let inspection) = status { return inspection }
        return nil
    }

    private let inspector: Inspector
    private var selected: [PhotoItem] = []
    private var context: [PhotoItem] = []
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    // Detached work is not a child of the awaiting task; cancel both.
    private var work: Task<Result<XMPExportSourceInspection, Error>, Never>?

    init(inspector: @escaping Inspector = { selected, context in
        try XMPExportPlanner.inspectSources(selected: selected, familyContextItems: context)
    }) {
        self.inspector = inspector
    }

    func inspect(selected: [PhotoItem], familyContextItems: [PhotoItem]) {
        self.selected = selected
        context = familyContextItems
        retry()
    }

    func retry() {
        cancel()
        let id = UUID()
        requestID = id
        begin()
        let selected = selected
        let context = context
        let inspector = inspector
        let work = Task.detached(priority: .utility) {
            Result { try inspector(selected, context) }
        }
        self.work = work
        task = Task { [weak self] in
            let result = await work.value
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.work = nil
            self.task = nil
            self.complete(result)
        }
    }

    func cancel() {
        requestID = UUID()
        work?.cancel()
        work = nil
        task?.cancel()
        task = nil
        status = .idle
    }

    func reset() {
        cancel()
        inclusionChoice = ExportXMPInclusionChoice()
    }

    func begin() { status = .checking }

    func complete(_ result: Result<XMPExportSourceInspection, Error>) {
        switch result {
        case .success(let inspection):
            status = .checked(inspection)
            inclusionChoice.applyRecognizedPacketCount(inspection.recognizedPacketCount)
        case .failure(let error):
            status = error is CancellationError ? .idle : .failed
        }
    }
}
