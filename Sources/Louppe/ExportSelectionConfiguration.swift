/// The Export sheet's starting choices and quick picks. Keeping this pure
/// makes the displayed count and the worker input follow the same selection.
enum ExportQuickPick: Equatable {
    case keepers
    case fourFiveStars
    case allSelected
}

struct ExportSelectionConfiguration: Equatable {
    var scope: CleanUpScope
    var predicate: ExportSelectionPredicate

    static func initial(
        hasExplicitSelection: Bool,
        keepersOnly: Bool
    ) -> Self {
        if keepersOnly {
            return preset(.keepers, keeperScope: .all)
        }
        return preset(hasExplicitSelection ? .allSelected : .keepers)
    }

    static func preset(
        _ pick: ExportQuickPick,
        keeperScope: CleanUpScope = .filtered
    ) -> Self {
        switch pick {
        case .keepers:
            return Self(
                scope: keeperScope,
                predicate: ExportSelectionPredicate(decisions: [.yes])
            )
        case .fourFiveStars:
            return Self(
                scope: .filtered,
                predicate: ExportSelectionPredicate(
                    decisions: [.yes, .no, .undecided],
                    starStates: [.stars(.four), .stars(.five)]
                )
            )
        case .allSelected:
            return Self(
                scope: .selected,
                predicate: ExportSelectionPredicate(
                    decisions: [.yes, .no, .undecided]
                )
            )
        }
    }

    func candidateIndices<All: Sequence>(
        all: All,
        filtered: [Int],
        selected: Set<Int>
    ) -> [Int] where All.Element == Int {
        scope.candidateIndices(
            all: all,
            filtered: filtered,
            selected: selected
        )
    }

    func snapshot(
        items: [PhotoItem],
        filtered: [Int],
        selected: Set<Int>,
        all: [Int]? = nil
    ) -> ExportSelectionSnapshot {
        let candidates: [Int]
        switch scope {
        case .all: candidates = all ?? Array(items.indices)
        case .filtered: candidates = filtered
        case .selected: candidates = selected.sorted()
        }
        return ExportSelectionSnapshot(
            items: items, candidateIndices: candidates, predicate: predicate)
    }
}
