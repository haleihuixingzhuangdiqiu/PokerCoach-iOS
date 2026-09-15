import XCTest
@testable import PokerCoachCore

final class OpeningSnapshotRangeModelTests: XCTestCase {
    private func opening(folds: Bool = false, unknownRules: Bool = false) throws -> OpeningSnapshotReconstruction {
        let rules = try PokerGameRules(smallBlind: 20, bigBlind: 50, utgStraddle: .optional(amount: 100))
        var state = try rules.startHand(seats: (0..<8).map { Seat(id: 100 + $0, stack: 5_000) },
            button: 7, optionalStraddle: true).state
        if folds { state = try state.applying(.fold).applying(.fold) }
        state = try state.applying(.raiseTo(280))
        if folds { state = try state.applying(.fold) }
        let snapshot = PublicTableSnapshot(seats: state.seats.map {
            .init(id: $0.id, stack: $0.stack, streetWager: $0.streetCommitted, folded: $0.folded)
        }, hero: state.actor!, cards: try HoleCards("QcQh"), board: [], pot: state.pot,
           button: state.button, actor: state.actor, rules: unknownRules ? nil : rules,
           optionalStraddle: true, straddleSeat: 2)
        return try OpeningSnapshotReconstructor.reconstruct(snapshot, ruleHypotheses: unknownRules ? [rules] : [])
    }
    private func assertSame(_ a: HandRange, _ b: HandRange, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.combos.map(\.hand), b.combos.map(\.hand), file: file, line: line)
        for (left, right) in zip(a.combos, b.combos) {
            XCTAssertEqual(left.weight, right.weight, accuracy: 1e-14, file: file, line: line)
        }
    }

    func testOnlyInferredOpenerIsConditionedAndRepeatedFrameDoesNotCountTwice() throws {
        let reconstruction = try opening()
        let prior = try HandRange.parse("AsAd,7h2s")
        let first = try PublicActionRangeModel.analyze(opening: reconstruction, prior: prior)
        let repeated = try PublicActionRangeModel.analyze(opening: reconstruction, prior: prior)
        XCTAssertFalse(reconstruction.historyComplete)
        XCTAssertEqual(Set(first.ranges.keys), [0, 1, 2, 3, 5, 6, 7])
        let aa = try HoleCards("AsAd")
        XCTAssertGreaterThan(try XCTUnwrap(first.ranges[3]?.combos.first { $0.hand == aa }?.weight), 0.5)
        for seat in first.ranges.keys {
            assertSame(try XCTUnwrap(first.ranges[seat]), try XCTUnwrap(repeated.ranges[seat]))
            XCTAssertEqual(first.actionsUsedBySeat[seat], seat == 3 ? 1 : 0)
            if seat != 3 { assertSame(try XCTUnwrap(first.ranges[seat]), prior) }
        }
        XCTAssertTrue(first.label.contains("快照推断"))
        XCTAssertTrue(first.label.contains("未校准"))
        XCTAssertTrue(first.limitations.contains { $0.contains("未观测到连续完整历史") })
    }

    func testKnownCardBlockersApplyToOpenerAndAllOtherLivePriors() throws {
        let reconstruction = try opening()
        let result = try PublicActionRangeModel.analyze(opening: reconstruction)
        for (seat, range) in result.ranges {
            XCTAssertEqual(range.combos.count, 1_225)
            XCTAssertTrue(range.combos.allSatisfy { $0.hand.mask & reconstruction.cards.mask == 0 })
            XCTAssertTrue(range.combos.allSatisfy { $0.weight.isFinite && $0.weight > 0 })
            XCTAssertEqual(range.combos.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-12)
            if seat != reconstruction.openerSeat {
                XCTAssertTrue(range.combos.allSatisfy { abs($0.weight - 1 / 1225.0) < 1e-12 })
            }
        }
        let blockedPrior = try HandRange.parse("QcAs,QhKd")
        XCTAssertThrowsError(try PublicActionRangeModel.analyze(opening: reconstruction, prior: blockedPrior))
    }

    func testTwoPercentCategoryNoisePreservesSupportForUnexpectedOpen() throws {
        let prior = try HandRange.parse("AsAd:3,7h2s:1")
        let reconstruction = try opening()
        // The check/call profile never raises. Under zero noise conditioning
        // would have zero evidence; the shared 2% noise gives a valid posterior.
        let result = try PublicActionRangeModel.analyze(opening: reconstruction, prior: prior, profiles: [.checkCall])
        assertSame(try XCTUnwrap(result.ranges[reconstruction.openerSeat]), prior)
        XCTAssertTrue(result.limitations.contains { $0.contains("2%类别噪声") })
        XCTAssertTrue(result.limitations.contains { $0.contains("未拟合具体开池尺寸") })
    }

    func testFoldedPlayersAreExcludedAndRuleHypothesisAssumptionIsDisclosed() throws {
        let reconstruction = try opening(folds: true, unknownRules: true)
        let result = try PublicActionRangeModel.analyze(opening: reconstruction)
        XCTAssertEqual(Set(result.ranges.keys), Set(reconstruction.state.live.filter { $0 != reconstruction.hero }))
        for folded in [3, 4, 6] { XCTAssertNil(result.ranges[folded]) }
        XCTAssertEqual(result.actionsUsedBySeat.values.reduce(0, +), 1)
        XCTAssertTrue(result.limitations.contains { $0.contains("规则候选已覆盖全部可能") })
    }

    func testTamperedBeforeStateOpenerEventsRulesAndAmountsCannotConditionRange() throws {
        let original = try opening()
        func altered(state: TableState? = nil, before: TableState? = nil, opener: Int? = nil,
                     raiseTo: Int? = nil, actions: [ReconstructedOpeningAction]? = nil,
                     rules: [OpeningRuleInterpretation]? = nil) -> OpeningSnapshotReconstruction {
            .init(state: state ?? original.state, stateBeforeOpening: before ?? original.stateBeforeOpening,
                hero: original.hero, cards: original.cards, openerSeat: opener ?? original.openerSeat,
                openingRaiseTo: raiseTo ?? original.openingRaiseTo,
                inferredActions: actions ?? original.inferredActions,
                compatibleRules: rules ?? original.compatibleRules, assumptions: original.assumptions)
        }
        var wrongBefore = original.stateBeforeOpening
        wrongBefore.seats[0].stack -= 1
        var wrongFinal = original.state
        wrongFinal.seats[0].committed += 1
        let invalid = [altered(before: wrongBefore), altered(state: wrongFinal), altered(opener: 2),
            altered(raiseTo: 300), altered(actions: original.inferredActions + original.inferredActions),
            altered(rules: []), altered(rules: [.init(rules: original.compatibleRules[0].rules,
                usesOptionalStraddle: false, straddleSeat: nil)])]
        for value in invalid { XCTAssertThrowsError(try PublicActionRangeModel.analyze(opening: value)) }
        XCTAssertThrowsError(try PublicActionRangeModel.analyze(opening: original, profiles: []))
    }

    func testCancellationDoesNotReturnPartiallyConditionedRanges() throws {
        var checkpoints = 0
        XCTAssertThrowsError(try PublicActionRangeModel.analyze(opening: opening(), isCancelled: {
            checkpoints += 1; return checkpoints > 5
        })) { error in
            guard case PokerError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
    }
}
