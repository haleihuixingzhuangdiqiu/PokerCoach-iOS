#!/usr/bin/env python3
"""Independent river-nuts examples, using PokerKit rather than the Swift evaluator.

Requires Python >= 3.11 and the optional dependency pokerkit==0.7.4:
    python3 -m pip install pokerkit==0.7.4
    python3 tools/audit_river_nuts_pokerkit.py

Each synthetic case exhausts all C(45, 2) = 990 legal opponent holdings.
This checks the stated sufficient-guard examples and beatable counterexamples;
it does not prove strategy strength or exhaustive coverage of every river board.
"""

import itertools
import json
from importlib.metadata import version

from pokerkit import Card, StandardHighHand


CASES = (
    ("AsKd", "QhJsTc2d3c", 0),
    ("As2s", "KsQs8s4d3h", 0),
    ("7h7d", "7s7cAhKd2c", 0),
    ("AhKh", "QcQdQhQs2c", 0),
    ("AhKh", "QhJhTh2c3d", 0),
    ("AsKd", "QhJhTh2d3c", 45),
    ("AsKd", "QhQsJcTd3c", 28),
    ("As2s", "QsJs9s4d3h", 2),
    ("Qs2s", "KsJs8s4d3h", 7),
    ("2c2d", "2h2s9c9dAh", 1),
    ("Kh2h", "QcQdQhQs3c", 170),
    ("6c7d", "8h9sTc2dAh", 28),
)


def main():
    if not __debug__:
        raise RuntimeError("Run without -O so the oracle assertions execute")
    if version("pokerkit") != "0.7.4":
        raise RuntimeError("This oracle is pinned to pokerkit==0.7.4")
    deck = tuple(Card.parse("".join(r + s for r in "23456789TJQKA" for s in "cdhs")))
    results = []
    for hero_text, board_text, expected in CASES:
        hero, board = tuple(Card.parse(hero_text)), tuple(Card.parse(board_text))
        assert len(set(hero + board)) == 7
        own_value = StandardHighHand.from_game(hero, board)
        remaining = [card for card in deck if card not in hero + board]
        compared = stronger = ties = 0
        for opponent in itertools.combinations(remaining, 2):
            other_value = StandardHighHand.from_game(opponent, board)
            compared += 1
            stronger += other_value > own_value
            ties += other_value == own_value
        assert compared == 990
        assert stronger == expected, (hero_text, board_text, stronger, expected)
        results.append(dict(hero=hero_text, board=board_text, compared=compared,
                            stronger=stronger, ties=ties, unbeatable=stronger == 0))
    print(json.dumps(dict(pokerkit=version("pokerkit"), cases=results,
                          passed=len(results)), indent=2))


if __name__ == "__main__":
    main()
