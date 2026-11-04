# Filing PoC — A-1: Distributor manufactured-yield steering (Morpheus / MOR)

Foundry fork PoC for finding **A-1** (`lanes/LANE-A.md` §4, confirmed in
`RECHECK.md` §A-1 and `ESCALATION.md` E1). This suite replaces the original
`poc/laneA/` PoC, which intermittently failed on re-run for a fork-harness
reason proven in `RECHECK.md` §A-1-PoC (ChainLink feed staleness after the
test's +86,401 s warp — see "Why this PoC is robust" below). The bug itself
was never in doubt; this file makes the *evidence* reproducible on demand.

## Run it (one command)

Prerequisites: Foundry (`forge`), and an **archive-capable** Ethereum
mainnet RPC endpoint (the fork is pinned to a historical block; a
non-archive node cannot serve its state).

```bash
cd poc/filing-A1
ETH_RPC_URL=<your archive RPC endpoint> forge test
```

Add `-vv` to see the logged deltas. That is the only step: the RPC endpoint
is read from the `ETH_RPC_URL` environment variable (see
`foundry.toml` → `[rpc_endpoints]`), and the fork block is pinned inside
the test itself (`vm.createSelectFork("mainnet", 26329065)`), so no
`--fork-url` / `--fork-block-number` flags are needed and the run cannot
silently target the wrong block. No keys or endpoints are hardcoded, no
mainnet transaction is sent, and nothing is published anywhere — the test
runs entirely against a local fork.

RPC note (measured 2026-11-03, `evidence/filing-A1-runs.txt`): the free
`https://eth.drpc.org` endpoint passed 4/4 runs. The free
`https://ethereum-rpc.publicnode.com` endpoint intermittently routes to
non-archive backends that fail in `setUp()` with
`historical state … is not available` (no test logic executes); on retry
against an archive-capable backend it passes with identical results.
Use any archive endpoint you trust.

## Pinned block

- **Ethereum mainnet block 26,329,065** (block timestamp 1,793,646,263) —
  the same block the lane audit, escalation suite and recheck all used, so
  every number in those reports is directly comparable.
- At this block, `Distributor.rewardPoolLastCalculatedTimestamp(0)` =
  1,793,531,771, i.e. the 24 h distribution period had already elapsed
  114,492 s earlier, and every ChainLink feed was still inside its allowed
  update delay (stETH age 912 s / delay 3,600 s; ETH 420 s / 3,600 s;
  USDC 18,900 s / 86,400 s; USDT 15,408 s / 86,400 s). The setup
  distribution therefore needs **no time warp** (asserted in the test).

## What the test does

Single test `test_A1_ManufacturedYieldSteering`, attacker = one **fresh,
unprivileged address** (no prank as any protocol role anywhere; the only
funding cheatcode is `deal`, endowing the attacker with their own stated
capital, as in the lane D precedent):

1. **Stake** — attacker stakes 200,000 USDT into the USDT DepositPool.
   `stake()` internally fires the already-due distribution with real,
   still-fresh feed data (no warp, no mocks yet) and settles the attacker
   at the post-distribution rate, like any real staker.
2. **Baseline branch** — snapshot branch: warp +86,401 s (one distribution
   period), refresh the feeds (see below), call the permissionless
   `Distributor.distributeRewards(0)`, record the USDT pool's allocation
   and the attacker's pending MOR.
3. **Attack branch** — revert to the same snapshot, attacker first
   **donates 500 USDT** by supplying to Aave V3 with
   `onBehalfOf = Distributor` (aUSDT minted straight to the Distributor —
   indistinguishable in `Distributor`'s accounting from earned yield),
   then the identical warp + distribution.
4. **Sweep / recovery** — the permissionless `Distributor.withdrawYield`
   forwards the donation to the protocol's fixed L1Sender as "yield";
   direct `Distributor.withdraw` by the donor reverts (DepositPool-gated)
   and an Aave withdraw by the donor reverts (the donor holds zero aUSDT).

### Assertions

| # | Assertion | Result at pinned block |
|---|---|---|
| (a) | USDT pool day allocation with donation **> 2×** without | **674.08 MOR → 2,550.44 MOR (3.78×)** |
| (b) | Attacker pending rewards increase **> 1,000 MOR** | **569.49 MOR → 2,154.73 MOR, incremental +1,585.24 MOR** for the 500 USDT donation |
| (c) | Donation swept to L1Sender (≥ 490 USDT), donor recovers 0, both direct recovery paths revert | **519.74 USDT swept** (500 donation + 19.74 genuine accrued); donor balance unchanged by the sweep |

Exact asserted deltas (wei, logged by the test and in
`evidence/filing-A1-runs.txt`): baseline allocation
`674080530699386843115`, baseline pending `569494832078686732551`,
attack allocation `2550443512860000121093`, attack pending
`2154734240099456510234`, incremental `1585239408020769777683`,
swept `519742683` (519.742683 USDT). These reproduce the independent
rechecker's diagnostic figures (`RECHECK.md` §A-1-PoC) to the displayed
precision.

### Preconditions — attacker capital (stated honestly)

- **200,000 USDT stake** — the attacker's own capital, deposited through
  the normal staking flow; it remains the attacker's recorded principal
  and is recoverable on live state after the 7-day withdraw lock. It makes
  the attacker ≈ 84.5% of the USDT pool's virtual deposits (live pool
  total ≈ 36,729 USDT), which is why they capture most of the steered
  allocation.
- **500 USDT donation** — consumed: swept to L1Sender as yield and not
  recoverable by the donor (assertion (c)).
- No other capital, account, or victim action is required. All protocol
  entry points used (`stake`, Aave `supply`, `distributeRewards`,
  `withdrawYield`) are permissionless.

## Why this PoC is robust (the staleness problem, and the fix)

The original lane PoC warped +86,401 s before *every* distribution on a
frozen fork. After such a warp, every ChainLink answer's `updatedAt` is
older than its feed's allowed delay (3,600 s for stETH/ETH feeds,
86,400 s for the stable feeds), so the real `ChainLinkDataConsumer`
returns 0 by design and `distributeRewards` reverts
`DR: price for pair is zero`. Whether the lane's file passed depended on
which archive backend the free RPC happened to route to. On live mainnet
that warp is real elapsed time during which ChainLink heartbeats keep
republishing the feeds — the staleness is purely a fork artefact.

This suite removes the artefact with the minimum possible scaffolding:

1. **No warp for the setup distribution** — the period had already
   elapsed at the pinned block (above), so the distribution the
   attacker's stake triggers runs on 100% real feed data.
2. **For the one distribution that inherently needs +86,401 s**, the test
   re-mocks **only the external ChainLink aggregator contracts'**
   `latestRoundData()` to return the **identical answer that aggregator
   returned at the pinned block** — read from the real aggregator earlier
   in the same run, with an in-test assertion that the value has not
   drifted — with `updatedAt` set to the current (warped) timestamp. That
   is exactly, and only, what a live heartbeat republication does. Feed
   addresses are **derived from deployed state** at runtime
   (Distributor → each pool's `chainLinkPath` → `consumer.getPathId` →
   `consumer.dataFeeds`), never hardcoded.
3. **No Morpheus contract is mocked, etched, or storage-written** —
   Distributor, DepositPool, RewardPool, the ChainLinkDataConsumer
   (its staleness check executes for real, against the refreshed
   timestamps) and Aave all run deployed bytecode, and no price *value*
   is ever changed, only the freshness timestamp a live heartbeat would
   have advanced.

Alternatives tried and rejected empirically (2026-11-03):

- *Warp backwards* so the stake lands inside the previous period and the
  steered distribution fires at the fork timestamp: the stake reverts
  inside Aave (its reserve timestamps sit ahead of the warped-back clock).
- *`vm.rollFork` to a real block ≥ 1 day later*: impossible at audit time
  (chain head was only ≈ 191 blocks past the pinned block — a real +1-day
  block does not yet exist), and non-deterministic for a filing anyway,
  since it would depend on uncontrolled live distribution state at the
  later block.
- *Mocking the ChainLinkDataConsumer* (the escalation suite's approach):
  works, but mocks a Morpheus contract; mocking the external aggregators
  instead keeps every Morpheus contract on real bytecode, so it is the
  stronger evidence.

## Reproducibility record

`evidence/filing-A1-runs.txt`: 3 consecutive runs, `forge clean` before
each — **3/3 PASS**, identical gas (3,592,966) and byte-identical deltas —
plus a cross-backend check on a second provider (PASS with identical gas
when routed to an archive-capable backend; see the RPC note above).

## Files

- `foundry.toml` — solc 0.8.20; RPC via `${ETH_RPC_URL}` only.
- `test/FilingA1.t.sol` — the suite (single test, snapshot-branched).
- `lib/forge-std/` — vendored test library (same copy as `poc/laneA`).
