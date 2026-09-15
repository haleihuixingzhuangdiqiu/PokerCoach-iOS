"""Independent PokerKit 0.7.4 checks for missing-action recovery boundaries.

Requires Python 3.11+ and pokerkit==0.7.4. Writes JSON to stdout; no private
footage or production Swift rules/evaluator is imported. Run without -O.
"""
from dataclasses import replace
from importlib.metadata import version
import json
from pokerkit import Automation, Mode, NoLimitTexasHoldem, State

if not __debug__:
    raise RuntimeError("Run without -O so the oracle assertions execute")
if version("pokerkit") != "0.7.4":
    raise RuntimeError("This oracle is pinned to pokerkit==0.7.4")

AUTO = (Automation.ANTE_POSTING, Automation.BLIND_OR_STRADDLE_POSTING)
HOLES = ("AsAd", "KsKd", "QsQd", "JsJd", "TsTd", "9s9d", "8s8d", "7s7d")

def game(straddle=True, stacks=None):
    blinds = (20, 50, 100) if straddle else (20, 50)
    template = NoLimitTexasHoldem((), True, 0, blinds, 50, mode=Mode.CASH_GAME)
    streets = (replace(template.streets[0], min_completion_betting_or_raising_amount=100 if straddle else 50), *template.streets[1:])
    state = State(AUTO, template.deck, template.hand_types, streets, template.betting_structure,
                  True, 0, blinds, 0, stacks or [5000]*8, 8, mode=Mode.CASH_GAME)
    for hole in HOLES: state.deal_hole(hole)
    return state

def public(s):
    return {"bets": list(s.bets), "stacks": list(s.stacks), "live": list(s.statuses),
            "pot": s.total_pot_amount, "actor": s.actor_index}

def internal(s):
    return {**public(s), "min_raise_to": s.min_completion_betting_or_raising_to_amount,
            "last_raise_increment": s.completion_betting_or_raising_amount,
            "acted": sorted(s.acted_player_indices), "pending": list(s.actor_indices)}

results = {}

# Source 0170-72 is rotated to PokerKit order SB,BB,UTG,UTG+1,...,BTN.
# Core5 folds; core6 opens280; core7 calls280; core0 now acts.
a = game(True)
a.fold(); a.complete_bet_or_raise_to(280); a.check_or_call()
b = game(False)
b.complete_bet_or_raise_to(100); b.fold(); b.complete_bet_or_raise_to(280); b.check_or_call()
assert public(a) == public(b)
assert a.total_pot_amount == 730 and a.actor_index == 6
assert a.min_completion_betting_or_raising_to_amount == b.min_completion_betting_or_raising_to_amount == 460
results["video0170_straddle_vs_prior_open_indistinguishable"] = {"straddle": internal(a), "no_straddle": internal(b)}

# Same numeric blind-only endpoint can be posted straddle or a voluntary UTG raise.
a = game(True)
b = game(False); b.complete_bet_or_raise_to(100)
assert public(a) == public(b)
assert a.min_completion_betting_or_raising_to_amount == 200
assert b.min_completion_betting_or_raising_to_amount == 150
results["forced_looking_endpoint_has_different_raise_minimum"] = {"straddle": internal(a), "no_straddle": internal(b)}

# Multiple equal B contributions are limps only under confirmed B. Straddler's
# free option remains pending until an actual check or raise occurs.
a = game(True)
for _ in range(7): a.check_or_call()
assert a.actor_index == 2 and a.checking_or_calling_amount == 0
assert a.min_completion_betting_or_raising_to_amount == 200
results["multiple_limp_straddle_option"] = internal(a)
before = public(a)
a.check_or_call()
assert a.actor_index is None
after = public(a)
assert all(before[k] == after[k] for k in ("bets", "stacks", "live", "pot"))
results["unknown_actor_zero_chip_check_ambiguous"] = {"before": before, "after": after}

# Exactly 2 full raises require at least 3B: 100 -> 200 -> 300.
a = game(True); a.complete_bet_or_raise_to(200)
assert a.min_completion_betting_or_raising_to_amount == 300
assert not a.can_complete_bet_or_raise_to(280)
a.complete_bet_or_raise_to(300)
assert a.min_completion_betting_or_raising_to_amount == 400
results["two_full_raise_lower_bound"] = internal(a)

# At a completed preflop endpoint equal M wagers can hide multiple raises.
# No bet collection automation means the unchanged chip endpoints remain visible.
a = game(True); a.complete_bet_or_raise_to(300)
for _ in range(7): a.check_or_call()
b = game(True); b.complete_bet_or_raise_to(200); b.complete_bet_or_raise_to(300)
for _ in range(7): b.check_or_call()
assert public(a) == public(b)
assert a.completion_betting_or_raising_amount == 200
assert b.completion_betting_or_raising_amount == 100
results["equal_calls_do_not_prove_single_open"] = {"single": internal(a), "two_raises": internal(b)}

# Counterpart of Swift LedgerPassiveGapTests: initial raise is already observed,
# only the subsequent calls/folds are absent between camera frames.
a = game(True); a.complete_bet_or_raise_to(280)
before = internal(a)
a.check_or_call(); a.fold(); a.check_or_call()
assert a.total_pot_amount == 1010 and a.actor_index == 7
assert a.completion_betting_or_raising_amount == 180
assert a.min_completion_betting_or_raising_to_amount == 460
results["passive_gap_after_observed_raise"] = {"before": before, "after": internal(a)}

stacks = [5000]*8; stacks[4] = 150
a = game(True, stacks); a.complete_bet_or_raise_to(300)
before = internal(a)
a.check_or_call(); a.check_or_call(); a.fold()
assert a.total_pot_amount == 920 and a.bets[4] == 150 and a.stacks[4] == 0
assert a.completion_betting_or_raising_amount == 200
assert a.min_completion_betting_or_raising_to_amount == 500
results["short_capped_call_is_not_a_raise"] = {"before": before, "after": internal(a)}

stacks = [5000]*8; stacks[4] = 250
a = game(True, stacks); a.complete_bet_or_raise_to(200); a.complete_bet_or_raise_to(250)
before = internal(a)
a.check_or_call(); a.fold(); a.check_or_call(); a.fold(); a.fold(); a.fold()
assert a.actor_index == 3 and a.checking_or_calling_amount == 50
assert not a.can_complete_bet_or_raise_to()
assert a.completion_betting_or_raising_amount == 100
results["passive_gap_preserves_closed_reopening_rights"] = {"before": before, "after": internal(a)}

# Net contributions can hide an uncalled raise at an all-in endpoint. PokerKit
# clears live wagers during collection; an OCR adapter must never presume its
# independently animated per-seat numbers establish that no refund occurred.
stacks = [100,100,100,1000,1000,1000,1000,1000]
a = game(True, stacks); a.check_or_call()
for _ in range(4): a.fold()
a.check_or_call(); a.check_or_call()
b = game(True, stacks); b.complete_bet_or_raise_to(200)
for _ in range(4): b.fold()
b.check_or_call(); b.check_or_call()
before = {"passive": internal(a), "raised": internal(b)}
a.collect_bets(); b.collect_bets()
assert public(a) == public(b)
assert a.total_pot_amount == b.total_pot_amount == 400
assert a.stacks[3] == b.stacks[3] == 900
results["refund_can_erase_unobserved_raise_at_all_in_endpoint"] = {"before_collection": before, "after_collection": public(a)}

report = {"pokerkit_version": version("pokerkit"), "checks": len(results), "results": results,
          "scope": "Design counterexamples; no production recovery implementation or video coverage claim."}
print(json.dumps(report, indent=2))
