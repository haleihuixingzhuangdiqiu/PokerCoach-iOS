"""Independent PokerKit 0.7.4 rule checks. Run with work/pokerkit-oracle on PYTHONPATH.

The WPK-supported rule specifies a 100 preflop minimum and 50 thereafter.
PokerKit's generic min_bet argument applies to every street, so construct the
street configuration explicitly instead of accidentally using 100 forever.
"""
from dataclasses import replace
from importlib.metadata import version
import json
from pathlib import Path
from pokerkit import Automation, Mode, NoLimitTexasHoldem, State


AUTOMATIONS = (Automation.ANTE_POSTING, Automation.BET_COLLECTION,
               Automation.BLIND_OR_STRADDLE_POSTING)
HOLES = ("AsAd", "KsKd", "QsQd", "JsJd", "TsTd", "9s9d", "8s8d", "7s7d", "6s6d")
results = {}


def game(stacks, blinds=(20, 50, 100), bb=50, preflop=100, ante=0):
    template = NoLimitTexasHoldem((), True, ante, blinds, bb, mode=Mode.CASH_GAME)
    streets = (replace(template.streets[0], min_completion_betting_or_raising_amount=preflop),
               *template.streets[1:])
    state = State(AUTOMATIONS, template.deck, template.hand_types, streets,
                  template.betting_structure, True, ante, blinds, 0, stacks,
                  len(stacks), mode=Mode.CASH_GAME)
    for hole in HOLES[:len(stacks)]:
        state.deal_hole(hole)
    return state


def snapshot(state):
    return {"actor": state.actor_index, "bets": list(state.bets),
            "stacks": list(state.stacks), "pot": state.total_pot_amount,
            "minimum_raise_to": state.min_completion_betting_or_raising_to_amount,
            "pots": [{"amount": pot.amount, "eligible": list(pot.player_indices)} for pot in state.pots]}


state = game([5000] * 8)
assert state.actor_index == 3
assert state.bets == [20, 50, 100, 0, 0, 0, 0, 0]
assert state.total_pot_amount == 170
assert state.min_completion_betting_or_raising_to_amount == 200
assert not state.can_complete_bet_or_raise_to(180)
assert state.can_complete_bet_or_raise_to(230)
results["eight_player_straddle"] = snapshot(state)
for _ in range(7):
    state.check_or_call()
assert state.actor_index == 2 and state.checking_or_calling_amount == 0
assert state.can_complete_bet_or_raise_to(200)
results["straddle_option"] = snapshot(state)
state.check_or_call()
state.burn_card("??")
state.deal_board("2c3d7h")
assert state.actor_index == 0
assert state.min_completion_betting_or_raising_to_amount == 50
results["flop_restores_big_blind"] = snapshot(state)

# Native generic configuration is intentionally different. This is evidence
# that simply passing a third blind does NOT encode the desired live-straddle minimum.
generic = NoLimitTexasHoldem.create_state(AUTOMATIONS, True, 0, (20, 50, 100), 50, [5000] * 8, 8)
for hole in HOLES[:8]:
    generic.deal_hole(hole)
assert generic.min_completion_betting_or_raising_to_amount == 150
results["generic_configuration_is_not_the_WPK_ruleset"] = snapshot(generic)

state = game([5000] * 8, ante=10)
assert state.total_pot_amount == 250 and state.checking_or_calling_amount == 100
results["antes_separate_from_live_bets"] = snapshot(state)

# Postflop short opening: 5 over a zero pot wager, minimum full raise is +10 => 15.
state = game([15, 100, 100], blinds=(5, 10), bb=10, preflop=10)
for _ in range(3):
    state.check_or_call()
state.burn_card("??")
state.deal_board("2c3d7h")
state.complete_bet_or_raise_to(5)
assert state.min_completion_betting_or_raising_to_amount == 15
assert not state.can_complete_bet_or_raise_to(10)
results["short_opening_raises_to_15"] = snapshot(state)


def after_short_raises(two):
    stacks = [5000] * 8
    stacks[4] = 250
    if two:
        stacks[5] = 300
    state = game(stacks)
    state.complete_bet_or_raise_to(200)
    state.complete_bet_or_raise_to(250)
    if two:
        state.complete_bet_or_raise_to(300)
    while state.actor_index != 3:
        state.check_or_call()
    return state


single = after_short_raises(False)
assert not single.can_complete_bet_or_raise_to()
results["single_short_raise_does_not_reopen"] = snapshot(single)
cumulative = after_short_raises(True)
assert cumulative.can_complete_bet_or_raise_to(400)
assert cumulative.min_completion_betting_or_raising_to_amount == 400
results["cumulative_full_raise_reopens"] = snapshot(cumulative)


def original_video_betting_point():
    # Seat 2 is hero/straddle. This reproduces the visible 1,852 pot, 100
    # hero contribution, two 280 wagers and the 1,122 all-in before hero.
    state = game([5000, 5000, 4963, 5000, 5000, 1122, 5000, 5000])
    state.complete_bet_or_raise_to(280)  # Seat 3.
    state.check_or_call()              # Seat 4.
    state.complete_bet_or_raise_to(1122)  # Seat 5 all-in.
    for _ in range(4):
        state.fold()                  # Seats 6,7,0,1.
    assert state.actor_index == 2 and state.total_pot_amount == 1852
    assert state.checking_or_calling_amount == 1022
    return state


state = original_video_betting_point()
results["video0186_before_hero"] = snapshot(state)
state.complete_bet_or_raise_to(2100)
state.check_or_call()
state.fold()
pots = [{"amount": p.amount, "eligible": list(p.player_indices)} for p in state.pots]
assert pots == [{"amount": 3716, "eligible": [2, 3, 5]}, {"amount": 1956, "eligible": [2, 3]}]
assert state.total_pot_amount == 5672
results["video_counterfactual_one_caller"] = snapshot(state)

state = original_video_betting_point()
state.complete_bet_or_raise_to(2100)
before_refund = state.stacks[2]
state.fold()
state.fold()
assert state.stacks[2] - before_refund == 978
assert state.total_pot_amount == 2874
results["video_counterfactual_uncalled_refund"] = {**snapshot(state), "refund": 978}

report = {"pokerkit_version": version("pokerkit"), "checks": len(results), "results": results,
          "scope": "Explicit full live-straddle street minima; no assertion that generic PokerKit matches short nominal blinds.",
          "sources": ["https://pokerkit.readthedocs.io/en/stable/simulation.html",
                      "https://raw.githubusercontent.com/uoftcprg/pokerkit/main/pokerkit/state.py"]}
target = Path(__file__).resolve().parents[1] / "reports" / "game-rules-pokerkit-audit.json"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({"pokerkit_version": report["pokerkit_version"], "passed": len(results), "report": str(target)}))
