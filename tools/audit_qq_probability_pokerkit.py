"""Independent QQ probability oracle using PokerKit 0.7.4 (optional dependency).

Run with PokerKit installed in the active Python 3.11+ environment. No production
Swift evaluator/sampler or private recordings are imported. This is seeded Monte
Carlo, NOT an exact enumeration or a prediction of actual opponents' holdings.
"""
import argparse
import json
from importlib.metadata import version
from math import sqrt
from pathlib import Path
from random import Random
from time import monotonic

from pokerkit import Card, StandardHighHand


def interval(mean, second, count):
    variance = max(0, (second - count * mean * mean) / (count - 1))
    # Descriptive normal approximation for this fixed-N, non-adaptive audit only.
    margin = 1.96 * sqrt(variance / count)
    return [max(0, mean - margin), min(1, mean + margin)]


def estimate(samples, seed, fixed_opponent=None):
    rng = Random(seed)
    hero = tuple(Card.parse('QcQh'))
    opponent = tuple(Card.parse(fixed_opponent)) if fixed_opponent else ()
    blocked = set(hero + opponent)
    deck = [c for c in Card.parse(''.join(r + s for r in '23456789TJQKA' for s in 'cdhs')) if c not in blocked]
    maximum = 1 if fixed_opponent else 7
    sums = [[0., 0., 0., 0.] for _ in range(maximum)]
    for _ in range(samples):
        cards = rng.sample(deck, 5 if fixed_opponent else 19)
        board = cards[:5]
        score = StandardHighHand.from_game(hero, board).entry.index
        best, tied = score, 1
        for index in range(maximum):
            hole = opponent if fixed_opponent else cards[5 + 2 * index:7 + 2 * index]
            other = StandardHighHand.from_game(hole, board).entry.index
            if other > best:
                best, tied = other, 1
            elif other == best:
                tied += 1
            share = 1 / tied if score == best else 0.
            sums[index][0] += share == 1
            sums[index][1] += 0 < share < 1
            sums[index][2] += share
            sums[index][3] += share * share
    rows = []
    for index, (wins, ties, share, squared) in enumerate(sums):
        value = share / samples
        rows.append(dict(opponents=index + 1, samples=samples, outright_win=wins / samples,
                         tie=ties / samples, equity=value, equity_approx_95=interval(value, squared, samples),
                         # P includes all existing chips, including the wager being faced.
                         hypothetical_call_ev_p450_c280=value * 730 - 280))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--samples', type=int, default=100_000)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    assert args.samples >= 2
    started = monotonic()
    result = dict(oracle='PokerKit StandardHighHand', version=version('pokerkit'), hero='QcQh',
                  method='Independent fixed-N seeded Monte Carlo; board and disjoint opponent hands uniform',
                  random=estimate(args.samples, 620_711),
                  fixed_AA=estimate(args.samples, 620_712, 'AhAs'),
                  fixed_AKs=estimate(args.samples, 620_713, 'AhKh'),
                  call_threshold_p450_c280=280 / 730,
                  limitations=['Random ranges are reference assumptions, not action-conditioned ranges.',
                               'EV formula assumes equal full-pot eligibility and no future betting.',
                               'Intervals describe sampling error for one row, not joint or model confidence.'])
    result['elapsed_seconds'] = monotonic() - started
    text = json.dumps(result, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + '\n')
    print(text)


if __name__ == '__main__':
    main()
