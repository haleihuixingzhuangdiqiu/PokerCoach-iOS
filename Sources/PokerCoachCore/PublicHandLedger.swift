import Foundation

/// Neutral, image-independent observations. Nil is unknown, never zero or not-folded.
/// Seats must contain every dealt participant in clockwise order, with stable external IDs.
public struct PublicSeatSnapshot: Sendable, Equatable, Codable {
    public let id: Int
    public var stack: Int?
    public var streetWager: Int?
    public var folded: Bool?
    public init(id: Int, stack: Int?, streetWager: Int?, folded: Bool?) {
        self.id = id; self.stack = stack; self.streetWager = streetWager; self.folded = folded
    }
}

public struct PublicTableSnapshot: Sendable, Equatable {
    public let seats: [PublicSeatSnapshot]
    public let hero: Int
    public let cards: HoleCards
    public let board: [Card]
    public let pot: Int?
    public let button: Int?
    /// Only set when the UI identifies whose turn it is.
    public let actor: Int?
    public let rules: PokerGameRules?
    public let optionalStraddle: Bool?
    public let straddleSeat: Int?
    public init(seats: [PublicSeatSnapshot], hero: Int, cards: HoleCards, board: [Card],
                pot: Int?, button: Int?, actor: Int?, rules: PokerGameRules? = nil,
                optionalStraddle: Bool? = nil, straddleSeat: Int? = nil) {
        self.seats = seats; self.hero = hero; self.cards = cards; self.board = board
        self.pot = pot; self.button = button; self.actor = actor; self.rules = rules
        self.optionalStraddle = optionalStraddle; self.straddleSeat = straddleSeat
    }
}

public struct LedgerAction: Sendable, Equatable, Codable {
    public let seatID: Int
    public let board: [Card]
    public let action: PokerAction
    /// Capture interval, not a measured human reaction time.
    public let observedAt: Double
}

public struct VerifiedPublicHand: Sendable, Equatable {
    public let id: UInt64
    public let state: TableState
    public let hero: Int
    public let cards: HoleCards
    public let rules: PokerGameRules
    public let usesOptionalStraddle: Bool
    public let straddleSeat: Int?
    /// Inferred only when every surviving legal reconstruction has the same path.
    public let actions: [LedgerAction]
    public let actionSequenceUnique: Bool
}

/// A strict rules ledger, not a guessed mid-hand state. It starts only from verifiable
/// forced bets, preserves contributions across streets, and rejects ambiguous raising rights.
/// Repeated fresh snapshots confirm transitions; incomplete frames withdraw freshness but
/// retain the last known ledger so a later, unambiguous observation can reconcile it.
public struct PublicHandLedger: Sendable {
    public private(set) var hand: VerifiedPublicHand?
    public private(set) var status = "等待完整开局记录"
    public private(set) var generation: UInt64 = 0
    public private(set) var lastVerifiedAt = 0.0
    private var lastInputAt = 0.0
    private var candidate: PublicTableSnapshot?
    private var candidateCount = 0
    /// A verified forced-bet frame may carry a brief explicit straddle label.
    /// Keep its original capture time: inherited labels do not extend its lifetime.
    private var openingEvidence: (snapshot: PublicTableSnapshot, timestamp: Double)?
    /// Legal transitions from individual frames can preserve fast action history,
    /// but are never actionable until an identical fresh snapshot confirms them.
    private var workingHand: VerifiedPublicHand?
    private var nextID: UInt64 = 0
    public let maxStates: Int
    public let maxActions: Int
    public let freshness: Double
    public init(maxStates: Int = 512, maxActions: Int = 32, freshness: Double = 0.8) {
        self.maxStates = max(1, min(4_096, maxStates))
        self.maxActions = max(1, min(64, maxActions))
        self.freshness = freshness.isFinite && freshness > 0 ? freshness : 0.8
    }
    public mutating func reset() {
        hand = nil; workingHand = nil; candidate = nil; openingEvidence = nil
        candidateCount = 0; lastVerifiedAt = 0; lastInputAt = 0
        generation &+= 1; status = "等待完整开局记录"
    }
    public mutating func ingest(_ snapshot: PublicTableSnapshot, timestamp: Double, now: Double) {
        guard timestamp.isFinite, now.isFinite, timestamp > lastInputAt, timestamp <= now,
              now - timestamp <= freshness else { return }
        let hadGap = lastInputAt > 0 && timestamp - lastInputAt > freshness
        lastInputAt = timestamp
        guard validShape(snapshot) else { openingEvidence = nil; invalidate("牌桌字段尚未完整"); return }
        let previous = workingHand ?? hand
        let sameHand = previous.map { compatibleIdentity($0, snapshot) } ?? false
        let target = sameHand ? fillingKnownFields(snapshot, from: previous!)
            : fillingOpeningLabels(snapshot, timestamp: timestamp)
        if hadGap || candidate != target { candidate = target; candidateCount = 1 }
        else { candidateCount += 1 }
        // Every changed/incomplete observation immediately withdraws the old advice.
        // Existing history may ingest a legal single-frame transition internally;
        // bootstrapping a hand and publishing advice still need two matching frames.
        lastVerifiedAt = 0
        if let previous, sameHand {
            guard complete(target) else { invalidate("多人筹码或行动尚未读全", keepCandidate: true); return }
            let reconciliation = reconcile(previous.state, with: target, timestamp: timestamp)
            if let result = reconciliation.result {
                let newHand = VerifiedPublicHand(id: previous.id, state: result.state, hero: previous.hero,
                    cards: previous.cards, rules: previous.rules, usesOptionalStraddle: previous.usesOptionalStraddle,
                    straddleSeat: previous.straddleSeat,
                    actions: previous.actions + (result.pathUnique ? result.actions : []),
                    actionSequenceUnique: previous.actionSequenceUnique && result.pathUnique)
                if newHand != previous { generation &+= 1 }
                workingHand = newHand
                guard candidateCount >= 2 else { status = "正在确认最新行动"; return }
                // Retain confirmed bookkeeping (including round completion) for
                // an already-published hand. A private bootstrap stays private
                // until the screen has actually identified an actor.
                if hand != nil || target.actor != nil { hand = newHand }
                guard target.actor != nil else { status = "牌局已核对，等待当前行动位置"; return }
                guard newHand.actionSequenceUnique else { status = "行动路径存在歧义，不能作为完整记录"; return }
                lastVerifiedAt = timestamp; status = "完整牌局已核对"; return
            }
            // A same-identity state must not be silently restarted as a new hand.
            invalidate(reconciliation.reason, keepCandidate: true); return
        }
        guard candidateCount >= 2 else { status = "正在核对完整牌局"; return }
        guard target.board.isEmpty else { invalidate("需要从本手盲注开始记录", keepCandidate: true); return }
        do {
            let started = try bootstrap(target, timestamp: timestamp)
            nextID &+= 1
            let newHand = VerifiedPublicHand(id: nextID, state: started.state, hero: target.hero,
                cards: target.cards, rules: target.rules!, usesOptionalStraddle: target.optionalStraddle ?? false,
                straddleSeat: started.straddleSeat, actions: started.actions, actionSequenceUnique: true)
            workingHand = newHand
            openingEvidence = nil
            candidate = fillingKnownFields(target, from: newHand)
            generation &+= 1
            guard target.actor != nil else {
                hand = nil; status = "开局已记录，等待当前行动位置"; return
            }
            hand = newHand; lastVerifiedAt = timestamp; status = "完整开局已核对"
        } catch { invalidate(String(describing: error), keepCandidate: true) }
    }
    /// Withdraw actionable freshness on a newer failed full-table read while
    /// retaining earlier bookkeeping for a later valid reconciliation.
    public mutating func ingestUnreadable(timestamp: Double, now: Double) {
        guard timestamp.isFinite, now.isFinite, timestamp > lastInputAt, timestamp <= now,
              now - timestamp <= freshness else { return }
        lastInputAt = timestamp; openingEvidence = nil
        invalidate("最新牌桌字段尚未读全")
    }
    public func current(now: Double) -> VerifiedPublicHand? {
        guard lastVerifiedAt > 0, now.isFinite, now >= lastVerifiedAt,
              now - lastVerifiedAt <= freshness else { return nil }
        return hand
    }
    private mutating func invalidate(_ reason: String, keepCandidate: Bool = false) {
        lastVerifiedAt = 0; status = reason
        if !keepCandidate { candidate = nil; candidateCount = 0 }
    }
    private func validShape(_ s: PublicTableSnapshot) -> Bool {
        (2...9).contains(s.seats.count) && s.seats.indices.contains(s.hero)
        && Set(s.seats.map(\.id)).count == s.seats.count
        && [0, 3, 4, 5].contains(s.board.count)
        && Set(s.cards.cards + s.board).count == 2 + s.board.count
        && (s.button.map { s.seats.indices.contains($0) } ?? true)
        && (s.actor.map { s.seats.indices.contains($0) } ?? true)
        && (s.pot.map { (0...9_000_000_000).contains($0) } ?? true)
        && s.seats.allSatisfy { seat in
            (seat.stack.map { (0...1_000_000_000).contains($0) } ?? true)
            && (seat.streetWager.map { (0...1_000_000_000).contains($0) } ?? true)
        }
    }
    private func complete(_ s: PublicTableSnapshot) -> Bool {
        s.pot != nil && s.seats.allSatisfy { $0.stack != nil && $0.streetWager != nil && $0.folded != nil }
    }
    private mutating func fillingOpeningLabels(_ s: PublicTableSnapshot, timestamp: Double) -> PublicTableSnapshot {
        var result = s
        if let evidence = openingEvidence {
            let prior = evidence.snapshot
            let sameForcedFrame = timestamp - evidence.timestamp <= freshness
                && s.hero == prior.hero && s.cards == prior.cards
                && s.button != nil && s.button == prior.button
                && s.board.isEmpty && prior.board.isEmpty
                && s.seats == prior.seats && s.pot == prior.pot
                && (s.rules == nil || s.rules == prior.rules)
                && (s.optionalStraddle == nil || s.optionalStraddle == prior.optionalStraddle)
                && (s.straddleSeat == nil || s.straddleSeat == prior.straddleSeat)
            if sameForcedFrame {
                result = .init(seats: s.seats, hero: s.hero, cards: s.cards, board: s.board,
                    pot: s.pot, button: s.button, actor: s.actor, rules: s.rules ?? prior.rules,
                    optionalStraddle: s.optionalStraddle ?? prior.optionalStraddle,
                    straddleSeat: s.straddleSeat ?? prior.straddleSeat)
            } else { openingEvidence = nil }
        }
        // Only fresh, explicit evidence can seed/renew this cache. In particular,
        // a 3-part blind label without an actual straddler cannot seed it.
        if s.board.isEmpty, (try? bootstrap(s, timestamp: timestamp)) != nil {
            openingEvidence = (s, timestamp)
        }
        return result
    }
    private func compatibleIdentity(_ h: VerifiedPublicHand, _ s: PublicTableSnapshot) -> Bool {
        h.hero == s.hero && h.cards == s.cards && h.state.seats.map(\.id) == s.seats.map(\.id)
        && (s.button == nil || s.button == h.state.button)
        && (s.rules == nil || s.rules == h.rules)
        && (s.optionalStraddle == nil || s.optionalStraddle == h.usesOptionalStraddle)
        && (s.straddleSeat == nil || s.straddleSeat == h.straddleSeat)
        && s.board.count >= h.state.board.count && Array(s.board.prefix(h.state.board.count)) == h.state.board
    }
    private func fillingKnownFields(_ s: PublicTableSnapshot, from hand: VerifiedPublicHand) -> PublicTableSnapshot {
        let state = hand.state
        var seats = s.seats
        for i in seats.indices {
            // Folding is monotonic inside a verified hand. An unknown stack/wager is
            // retained only if a freshly read unchanged balance proves no new chips moved.
            if seats[i].folded == nil && state.seats[i].folded { seats[i].folded = true }
            if seats[i].streetWager == nil && s.board == state.board && seats[i].stack == state.seats[i].stack {
                seats[i].streetWager = state.seats[i].streetCommitted
            }
        }
        return .init(seats: seats, hero: s.hero, cards: s.cards, board: s.board, pot: s.pot,
                     button: s.button ?? state.button, actor: s.actor, rules: s.rules ?? hand.rules,
                     optionalStraddle: s.optionalStraddle ?? hand.usesOptionalStraddle,
                     straddleSeat: s.straddleSeat ?? hand.straddleSeat)
    }
    private func matches(_ state: TableState, _ s: PublicTableSnapshot) -> Bool {
        state.board == s.board && state.pot == s.pot
        && (s.actor == nil || state.actor == s.actor)
        && state.seats.indices.allSatisfy { i in
            state.seats[i].stack == s.seats[i].stack && state.seats[i].streetCommitted == s.seats[i].streetWager
            && state.seats[i].folded == s.seats[i].folded
        }
    }
    private func bootstrap(_ s: PublicTableSnapshot, timestamp: Double) throws
        -> (state: TableState, actions: [LedgerAction], straddleSeat: Int?) {
        guard complete(s), let rules = s.rules, let button = s.button,
              s.seats[s.hero].folded == false, rules.ante == 0 else {
            throw PokerError.invalid("开局需要全部筹码、庄家及盲注")
        }
        if case .optional = rules.utgStraddle, s.optionalStraddle == nil {
            throw PokerError.invalid("尚未确认本手是否实际投入第三盲")
        }
        let seats = s.seats.map { Seat(id: $0.id, stack: $0.stack! + $0.streetWager!) }
        let start = try rules.startHand(seats: seats, button: button, optionalStraddle: s.optionalStraddle ?? false)
        guard start.positions.straddle == s.straddleSeat,
              start.state.pot == s.pot,
              start.state.seats.indices.allSatisfy({ start.state.seats[$0].streetCommitted == s.seats[$0].streetWager }) else {
            throw PokerError.invalid("已错过本手盲注记录或第三盲位置不一致")
        }
        var state = start.state, actions: [LedgerAction] = []
        // Only a forced-bet snapshot and a legal prefix of visible folds can bootstrap.
        // A same-stack check or a completed orbit is never guessed here.
        while let i = state.actor, actions.count < s.seats.count,
              s.actor.map({ $0 != i }) ?? (s.seats[i].folded == true) {
            guard s.seats[i].folded == true else { throw PokerError.invalid("开局行动顺序尚未核对") }
            actions.append(.init(seatID: state.seats[i].id, board: [], action: .fold, observedAt: timestamp))
            state = try state.applying(.fold)
        }
        if s.actor == nil {
            // With only forced wagers, a nonfolded player who still owes chips
            // cannot have acted without a visible payment/fold. At a free-check
            // option, however, the same balances may hide an already-taken action.
            guard let i = state.actor, state.amountToCall(i) > 0 else {
                throw PokerError.invalid("开局行动位置未知，不能排除已让牌")
            }
        }
        guard matches(state, s) else { throw PokerError.invalid("开局金额或弃牌记录不一致") }
        return (state, actions, start.positions.straddle)
    }

    private struct Node { let state: TableState; let actions: [LedgerAction]; let depth: Int }
    private struct Reconstruction { let state: TableState; let actions: [LedgerAction]; let pathUnique: Bool }
    private func reconcile(_ initial: TableState, with target: PublicTableSnapshot, timestamp: Double)
        -> (result: Reconstruction?, reason: String) {
        guard target.seats.indices.allSatisfy({ target.seats[$0].stack! <= initial.seats[$0].stack
            && (!initial.seats[$0].folded || target.seats[$0].folded == true) }) else {
            return (nil, "筹码或弃牌状态与本手记录冲突")
        }
        // With two chip-paying players between captures, hidden intermediate raises can
        // produce the same endpoint but different last-full-raise/reopening rights.
        // Endpoint-only search cannot prove their absence. Wait for a new verified hand.
        guard target.seats.indices.filter({ target.seats[$0].stack! < initial.seats[$0].stack }).count <= 1 else {
            return (nil, "两次画面间多名玩家投入，缺少中间加注记录")
        }
        var queue = [Node(state: initial, actions: [], depth: 0)], cursor = 0
        var matchesFound: [Node] = []
        var reachedActionLimit = false
        while cursor < queue.count {
            guard queue.count <= maxStates else { return (nil, "遗漏动作过多，无法唯一还原") }
            let node = queue[cursor]; cursor += 1
            if matches(node.state, target) {
                matchesFound.append(node)
                // Stop each matching branch at its minimal observed prefix. Search
                // the OTHER branches too: an unknown actor must not hide a different
                // check/fold history that reaches these same balances.
                continue
            }
            guard node.depth < maxActions else { reachedActionLimit = true; continue }
            guard node.state.live.count > 1 else { continue }
            if node.state.roundComplete {
                let count = node.state.board.isEmpty ? 3 : node.state.board.count + 1
                guard count <= target.board.count,
                      let next = try? node.state.advancing(to: Array(target.board.prefix(count))) else { continue }
                queue.append(.init(state: next, actions: node.actions, depth: node.depth + 1)); continue
            }
            guard let i = node.state.actor else { continue }
            let observed = target.seats[i], seat = node.state.seats[i]
            let remaining = seat.stack - observed.stack!
            var possible: [PokerAction] = []
            if observed.folded == true { possible.append(.fold) }
            if node.state.amountToCall(i) == 0 { possible.append(.check) }
            else if node.state.amountToCall(i) <= remaining { possible.append(.call) }
            // Only observed chip endpoints are candidate raise totals. Unknown intermediate
            // raises are not enumerated or silently fabricated; those gaps remain unverified.
            let raise = seat.streetCommitted + remaining
            if remaining > 0 && raise > node.state.currentBet { possible.append(.raiseTo(raise)) }
            for action in possible {
                guard let next = try? node.state.applying(action), next.pot <= target.pot!,
                      next.seats.indices.allSatisfy({ next.seats[$0].stack >= target.seats[$0].stack! }),
                      !(next.seats[i].folded && next.seats[i].stack != observed.stack!) else { continue }
                if next.board == target.board && next.seats[i].streetCommitted > observed.streetWager! { continue }
                let event = LedgerAction(seatID: seat.id, board: node.state.board, action: action, observedAt: timestamp)
                queue.append(.init(state: next, actions: node.actions + [event], depth: node.depth + 1))
            }
        }
        guard !reachedActionLimit else { return (nil, "动作重放达到上限，不能证明记录唯一") }
        guard let first = matchesFound.first else { return (nil, "本手动作记录尚不能还原") }
        guard matchesFound.allSatisfy({ $0.state == first.state }) else { return (nil, "加注权或行动顺序存在多种可能") }
        return (.init(state: first.state, actions: first.actions,
                      pathUnique: matchesFound.allSatisfy { $0.actions == first.actions }), "")
    }
}
