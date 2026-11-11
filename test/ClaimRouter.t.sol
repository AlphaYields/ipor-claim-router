// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ClaimRouter} from "../src/ClaimRouter.sol";
import {IPlasmaVault, IWithdrawManager} from "../src/IFusion.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC4626Mint {
    function deposit(uint256, address) external returns (uint256);
}

interface IWM2 {
    function requestShares(uint256) external;
    function releaseFunds(uint256, uint256) external;
    function getSharesToRelease() external view returns (uint256);
}

interface IWM3 {
    function requestInfo(address) external view returns (uint256, uint256);
}

/// Fork tests against the live ayKAT vault on Katana. Everything is exercised through
/// the real PlasmaVault and WithdrawManager — no mocks of the protocol.
/// Tries to re-enter claimFor while a claim is in flight.
contract Reenterer {
    ClaimRouter public immutable ROUTER;
    address public immutable TARGET;
    bool public tried;
    bool public succeeded;

    constructor(ClaimRouter r, address t) {
        ROUTER = r;
        TARGET = t;
    }

    function go() external {
        ROUTER.claimFor(TARGET);
    }

    // invoked if the asset token ever calls back into us
    fallback() external payable {
        if (!tried) {
            tried = true;
            try ROUTER.claimFor(TARGET) {
                succeeded = true;
            }
                catch {}
        }
    }
    receive() external payable {}
}

contract ClaimRouterTest is Test {
    address constant VAULT = 0x94Ff40197900a6Ea5D9D63C691d89e70aC1343d6;
    address constant WM = 0x25B2f567CF4141AE62035B8b062a51C2B562A4E2;
    address constant AVKAT = 0x7231dbaCdFc968E07656D12389AB20De82FbfCeB;
    address constant KAT = 0x7F1f4b4b29f5058fA32CC7a97141b8D7e5ABDC2d;
    address constant MORPHO = 0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc; // KAT whale
    address constant ALPHA = 0x3C2e546d5FB729Afa62AcC93F89Cbe9612388dE1;

    ClaimRouter router;
    address user = makeAddr("user");
    address keeper = makeAddr("keeper");
    address rando = makeAddr("rando");

    function setUp() public {
        vm.createSelectFork(vm.envString("KATANA_RPC"));
        router = new ClaimRouter(VAULT, WM);
        _fundWithShares(user, 400_000e18);
    }

    function _fundWithShares(address who, uint256 katAmount) internal {
        vm.prank(MORPHO);
        IERC20(KAT).transfer(who, katAmount);
        vm.startPrank(who);
        IERC20(KAT).approve(AVKAT, type(uint256).max);
        IERC4626Mint(AVKAT).deposit(katAmount, who);
        uint256 av = IERC20(AVKAT).balanceOf(who);
        IERC20(AVKAT).approve(VAULT, type(uint256).max);
        IERC4626Mint(VAULT).deposit(av, who);
        vm.stopPrank();
    }

    function _request(address who, uint256 shares) internal {
        vm.prank(who);
        IWM2(WM).requestShares(shares);
    }

    function _release(uint256 shares) internal {
        vm.prank(ALPHA);
        IWM2(WM).releaseFunds(block.timestamp - 1, shares);
    }

    // ── deployment guards ────────────────────────────────────────────────────
    function test_constructor_rejectsZeroVault() public {
        vm.expectRevert(ClaimRouter.ZeroAddress.selector);
        new ClaimRouter(address(0), WM);
    }

    function test_constructor_rejectsZeroManager() public {
        vm.expectRevert(ClaimRouter.ZeroAddress.selector);
        new ClaimRouter(VAULT, address(0));
    }

    function test_constructor_rejectsMismatchedPair() public {
        // AVKAT is a real contract but not this vault's withdraw manager
        vm.expectRevert();
        new ClaimRouter(AVKAT, WM);
    }

    function test_constructor_wiresImmutables() public view {
        assertEq(address(router.VAULT()), VAULT);
        assertEq(address(router.WITHDRAW_MANAGER()), WM);
    }

    // ── the core invariant ───────────────────────────────────────────────────
    function test_claimFor_paysTheOwnerAndNobodyElse() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);

        uint256 ownerBefore = IERC20(AVKAT).balanceOf(user);
        uint256 callerBefore = IERC20(AVKAT).balanceOf(rando);
        uint256 routerBefore = IERC20(AVKAT).balanceOf(address(router));

        vm.prank(rando);
        uint256 assets = router.claimFor(user);

        assertGt(assets, 0, "nothing settled");
        assertEq(IERC20(AVKAT).balanceOf(user), ownerBefore + assets, "owner not paid");
        assertEq(IERC20(AVKAT).balanceOf(rando), callerBefore, "caller received something");
        assertEq(IERC20(AVKAT).balanceOf(address(router)), routerBefore, "router held funds");
    }

    /// The property that makes a standing approval safe: no request, no claim.
    function test_claimFor_cannotForceRedeemWithoutARequest() public {
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);

        uint256 before = IERC20(VAULT).balanceOf(user);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(ClaimRouter.NothingToClaim.selector, user));
        router.claimFor(user);
        assertEq(IERC20(VAULT).balanceOf(user), before, "shares moved without a request");
    }

    function test_claimFor_revertsWithoutApproval() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.prank(rando);
        vm.expectRevert();
        router.claimFor(user);
    }

    function test_claimFor_revertsOnZeroOwner() public {
        vm.expectRevert(ClaimRouter.ZeroAddress.selector);
        router.claimFor(address(0));
    }

    /// The vulnerability this router exists to contain: IPOR's WithdrawManager never
    /// clears a settled request, so without our own ledger a standing approval could be
    /// drained by repeated calls.
    function test_claimFor_cannotBeReplayedToDrainTheOwner() public {
        uint256 all = IERC20(VAULT).balanceOf(user);
        uint256 req = all / 4;
        _request(user, req);
        _release(req);
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);

        vm.prank(rando);
        router.claimFor(user);
        uint256 afterFirst = IERC20(VAULT).balanceOf(user);

        // the protocol still reports the request as outstanding...
        (uint256 stillRequested,) = IWM3(WM).requestInfo(user);
        assertGt(stillRequested, 0, "precondition: manager clears requests");

        // ...but the router refuses, five times over
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(rando);
            vm.expectRevert();
            router.claimFor(user);
        }
        assertEq(IERC20(VAULT).balanceOf(user), afterFirst, "owner was drained by replay");
    }

    /// A fresh request after a settled one must work.
    function test_claimFor_allowsASecondRequestLater() public {
        uint256 all = IERC20(VAULT).balanceOf(user);
        uint256 req = all / 4;
        _request(user, req);
        _release(req);
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);
        vm.prank(rando);
        router.claimFor(user);

        vm.warp(block.timestamp + 1 hours);
        uint256 req2 = IERC20(VAULT).balanceOf(user) / 4;
        _request(user, req2);
        _release(req2);

        uint256 before = IERC20(VAULT).balanceOf(user);
        vm.prank(rando);
        assertGt(router.claimFor(user), 0, "second request not settleable");
        assertLt(IERC20(VAULT).balanceOf(user), before, "nothing settled");
    }

    function test_claimFor_isIdempotent() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);

        vm.prank(keeper);
        router.claimFor(user);

        vm.prank(keeper);
        vm.expectRevert(); // AlreadySettled — the request is spent
        router.claimFor(user);
    }

    function test_claimFor_neverExceedsTheRequest() public {
        uint256 all = IERC20(VAULT).balanceOf(user);
        uint256 shares = all / 4;
        _request(user, shares);
        _release(shares);
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);

        vm.prank(rando);
        router.claimFor(user);

        // only the requested quarter may leave, even though the approval covered all
        assertApproxEqRel(IERC20(VAULT).balanceOf(user), all - shares, 1e15, "claimed more than requested");
    }

    function test_ownerCanClaimForThemselves() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.startPrank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);
        uint256 assets = router.claimFor(user);
        vm.stopPrank();
        assertGt(assets, 0);
    }

    // ── the owner-set floor ──────────────────────────────────────────────────
    function test_floor_blocksThirdPartyBelowIt() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.startPrank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);
        router.setMinAssetsPerShare(100e18); // absurdly high
        vm.stopPrank();

        vm.prank(rando);
        vm.expectRevert();
        router.claimFor(user);
    }

    function test_floor_doesNotApplyToTheOwner() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.startPrank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);
        router.setMinAssetsPerShare(100e18);
        uint256 assets = router.claimFor(user); // owner bypasses their own floor
        vm.stopPrank();
        assertGt(assets, 0);
    }

    function test_floor_passesWhenMet() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.startPrank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);
        router.setMinAssetsPerShare(1e17); // 0.1 avKAT per share — easily met
        vm.stopPrank();

        vm.prank(rando);
        assertGt(router.claimFor(user), 0);
    }

    function test_floor_isPerOwnerAndSelfOnly() public {
        vm.prank(rando);
        router.setMinAssetsPerShare(5e18);
        assertEq(router.minAssetsPerShare(rando), 5e18);
        assertEq(router.minAssetsPerShare(user), 0, "one account set another's floor");
    }

    // ── keeper helper ────────────────────────────────────────────────────────
    function test_claimable_reportsFalseWithoutRequest() public view {
        (uint256 shares, bool ready) = router.claimable(user);
        assertEq(shares, 0);
        assertFalse(ready);
    }

    function test_claimable_reportsFalseWithoutApproval() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        (, bool ready) = router.claimable(user);
        assertFalse(ready, "ready despite no approval");
    }

    function test_claimable_matchesWhatClaimForSettles() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);

        (uint256 predicted, bool ready) = router.claimable(user);
        assertTrue(ready);
        uint256 before = IERC20(VAULT).balanceOf(user);
        vm.prank(keeper);
        router.claimFor(user);
        assertEq(before - IERC20(VAULT).balanceOf(user), predicted, "prediction mismatch");
    }

    // ── no admin surface ─────────────────────────────────────────────────────
    function test_routerHasNoOwnerOrUpgradePath() public {
        (bool okOwner,) = address(router).call(abi.encodeWithSignature("owner()"));
        (bool okUpg,) = address(router).call(abi.encodeWithSignature("upgradeTo(address)"));
        assertFalse(okOwner, "router exposes owner()");
        assertFalse(okUpg, "router exposes upgradeTo()");
    }

    function test_routerNeverHoldsShares() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);
        vm.prank(rando);
        router.claimFor(user);
        assertEq(IERC20(VAULT).balanceOf(address(router)), 0);
        assertEq(IERC20(AVKAT).balanceOf(address(router)), 0);
    }

    function test_reentrancyGuardHolds() public {
        Reenterer att = new Reenterer(router, user);
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);

        uint256 before = IERC20(VAULT).balanceOf(user);
        att.go();
        // exactly one settlement, never two
        assertEq(before - IERC20(VAULT).balanceOf(user), shares, "more than one settlement");
        assertFalse(att.succeeded(), "re-entrant claim succeeded");
    }

    function test_revokedApprovalStopsTheKeeper() public {
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.startPrank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);
        IERC20(VAULT).approve(address(router), 0); // user changes their mind
        vm.stopPrank();

        vm.prank(rando);
        vm.expectRevert();
        router.claimFor(user);
    }

    function test_partialFillCanBeFinishedLater() public {
        uint256 all = IERC20(VAULT).balanceOf(user);
        uint256 req = all / 2;
        _request(user, req);
        _release(req);
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);

        (uint256 predicted,) = router.claimable(user);
        vm.prank(rando);
        router.claimFor(user);
        (, uint256 claimed) = router.settlement(user);
        assertEq(claimed, predicted, "ledger disagrees with what was settled");
        assertLe(claimed, req, "settled more than requested");
    }

    // ── fuzz ─────────────────────────────────────────────────────────────────
    function testFuzz_claimFor_onlyEverPaysTheOwner(address caller) public {
        vm.assume(caller != address(0) && caller != user && caller.code.length == 0);
        uint256 shares = IERC20(VAULT).balanceOf(user) / 2;
        _request(user, shares);
        _release(shares);
        vm.prank(user);
        IERC20(VAULT).approve(address(router), type(uint256).max);

        uint256 callerBefore = IERC20(AVKAT).balanceOf(caller);
        uint256 ownerBefore = IERC20(AVKAT).balanceOf(user);
        vm.prank(caller);
        uint256 assets = router.claimFor(user);
        assertEq(IERC20(AVKAT).balanceOf(caller), callerBefore, "caller was paid");
        assertEq(IERC20(AVKAT).balanceOf(user), ownerBefore + assets, "owner shortchanged");
    }
}
