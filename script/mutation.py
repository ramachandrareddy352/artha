#!/usr/bin/env python3
"""Mutation campaign for the Artha test suite.

Coverage says a line executed. Only mutation says the suite would NOTICE if that line
were wrong. Each entry below deliberately breaks one invariant-bearing line; the suite
must fail. A mutant that SURVIVES is a line nothing actually constrains.

Usage:  python script/mutation.py
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

MUTANTS = [
    (
        "share maths: deposit rounds shares UP instead of down",
        "src/libraries/LibVaultMath.sol",
        "return Math.mulDiv(assets, _supply() + offset, ta + 1, Math.Rounding.Floor);",
        "return Math.mulDiv(assets, _supply() + offset, ta + 1, Math.Rounding.Ceil);",
        "test/property/ShareMath.t.sol",
    ),
    (
        "share maths: redeem rounds assets UP instead of down",
        "src/libraries/LibVaultMath.sol",
        "return Math.mulDiv(shares, ta + 1, _supply() + offset, Math.Rounding.Floor);",
        "return Math.mulDiv(shares, ta + 1, _supply() + offset, Math.Rounding.Ceil);",
        "test/property/ShareMath.t.sol",
    ),
    (
        "breaker: an unfunded strategy's first reading is trusted again",
        "src/libraries/LibVaultNav.sol",
        "if (lastValue == 0) return newValue != 0;",
        "if (lastValue == 0) return false;",
        "test/attack/MaliciousStrategy.t.sol",
    ),
    (
        "registry: receipt-collision check removed",
        "src/libraries/LibStrategyRegistry.sol",
        'require(r != receipt, "RECEIPT_COLLISION");',
        "r = r;",
        "test/attack/MaliciousStrategy.t.sol",
    ),
    (
        "registry: base-asset receipt is allowed again",
        "src/libraries/LibStrategyRegistry.sol",
        'require(receipt != s.baseAsset, "RECEIPT_IS_BASE_ASSET");',
        "receipt = receipt;",
        "test/attack/MaliciousStrategy.t.sol",
    ),
    (
        "withdraw queue: shortfall no longer reverts",
        "src/facets/WithdrawFacet.sol",
        'require(remaining == 0, "INSUFFICIENT_LIQUIDITY");',
        "remaining = 0;",
        "test/queue/WithdrawalQueue.t.sol",
    ),
    (
        "fees: the high-water mark never ratchets",
        "src/libraries/LibVaultFee.sol",
        "s.highWaterMarkPps = pps;",
        "s.highWaterMarkPps = hwm;",
        "test/facets/PerformanceFee.t.sol",
    ),
    (
        "rewards: unsettled accrual is ignored by outstandingArtha again",
        "src/rewards/UserRewardSystem.sol",
        "return (gross - debt) / 1e18;",
        "return 0;",
        "test/modules/Rewards.t.sol",
    ),
    (
        "rewards: the reward-rate ceiling is removed",
        "src/rewards/UserRewardSystem.sol",
        'require(_newRate <= MAX_REWARD_RATE, "RATE_TOO_HIGH");',
        "_newRate = _newRate;",
        "test/modules/Rewards.t.sol",
    ),
    (
        "strategy: base-custody divest pays out the whole balance, ignoring the request",
        "src/strategies/BaseStrategy.sol",
        "withdrawn = assets < bal ? assets : bal;",
        "withdrawn = bal;",
        "test/unit/BaseStrategy.t.sol",
    ),
    (
        "rewards engine: a failing claim takes the harvest down again",
        "src/strategies/common/MultiRewardStrategy.sol",
        "try this.claimRewards() {}",
        "if (block.timestamp > 0) { this.claimRewards(); } else",
        "test/unit/MultiRewardStrategy.t.sol",
    ),
    (
        "oracle: stale prices are accepted",
        "src/oracle/sources/ChainlinkSource.sol",
        'require(block.timestamp - updatedAt <= _maxAge, "STALE_PRICE");',
        "_maxAge = _maxAge;",
        "test/attack/OracleManipulation.t.sol",
    ),
    (
        "deposit: the balance-delta check on the pulled amount is removed",
        "src/facets/DepositFacet.sol",
        'require(received == assets, "TRANSFER_MISMATCH");',
        "received = assets;",
        "test/property/ShareMath.t.sol",
    ),
]


def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, shell=True, capture_output=True, text=True)


def main():
    killed, survived, broken = [], [], []

    for name, rel, original, mutated, test_path in MUTANTS:
        path = ROOT / rel
        source = path.read_text(encoding="utf-8")

        if original not in source:
            broken.append((name, "anchor text not found — mutation needs updating"))
            print(f"[SKIP] {name}\n       anchor not found in {rel}")
            continue

        path.write_text(source.replace(original, mutated, 1), encoding="utf-8")
        try:
            result = run(f'forge test --match-path "{test_path}" 2>&1')
            output = result.stdout + result.stderr
            compiled = "Compiler run failed" not in output and "Error (" not in output

            if not compiled:
                broken.append((name, "mutant does not compile"))
                print(f"[SKIP] {name}\n       mutant does not compile")
            elif "FAILED" in output or "[FAIL" in output:
                killed.append(name)
                print(f"[KILLED]   {name}")
            else:
                survived.append((name, test_path))
                print(f"[SURVIVED] {name}\n           nothing in {test_path} constrains this")
        finally:
            path.write_text(source, encoding="utf-8")

    total = len(killed) + len(survived)
    print("\n" + "=" * 70)
    print(f"killed:   {len(killed)}")
    print(f"survived: {len(survived)}")
    print(f"skipped:  {len(broken)}")
    if total:
        print(f"score:    {100 * len(killed) // total}%")
    for n, t in survived:
        print(f"  SURVIVOR: {n}  ({t})")
    for n, why in broken:
        print(f"  SKIPPED:  {n}  ({why})")

    print()
    print("not scored — provably unreachable while the never-funded rule stands:")
    print("  breaker: the absolute overflow ceiling. Isolating it needs lastValue > 2^127,")
    print("  which no sequence of real deposits can produce. Kept as defence in depth.")

    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())
