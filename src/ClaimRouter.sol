// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPlasmaVault, IWithdrawManager} from "./IFusion.sol";

/// @title ClaimRouter
/// @notice Settles an IPOR Fusion redemption request on a depositor's behalf, so they do
///         not have to come back and claim once their request is released.
///
/// @dev **The receiver is hardcoded to the owner.** This contract never names a
///      destination, never holds funds, has no admin and no upgrade path. Any caller — a
///      keeper, the user, or a stranger — can only push a user's own released redemption
///      to that same user's address.
///
///      Three further properties keep a standing approval from being abusable:
///
///      1. **Request-bound.** A claim settles at most what the WithdrawManager says the
///         owner has queued. An approval alone redeems nothing.
///      2. **Settled once per request.** IPOR's WithdrawManager does NOT clear a request
///         after redemption — `requestInfo` keeps reporting the original shares, and the
///         vault will happily redeem against it again while idle liquidity lasts. Left
///         unguarded, repeated calls would drain an approving user's whole balance. This
///         router therefore keeps its own per-owner ledger keyed on the request's
///         withdraw window, and never settles more than the request in total. Partial
///         settlements are tracked, so a request that could only be half-filled can be
///         finished later rather than being burned.
///      3. **Owner-set floor.** An owner may require a minimum assets-per-share before a
///         third party may settle for them, so a caller cannot pick a moment when the
///         share price is temporarily depressed. The owner is never subject to their own
///         floor.
contract ClaimRouter {
    /// @notice The vault whose shares this router settles. Immutable by design — a
    ///         repointable router would turn a user's approval into a blank cheque.
    IPlasmaVault public immutable VAULT;

    /// @notice The vault's withdraw manager, cross-checked against VAULT at deploy time.
    IWithdrawManager public immutable WITHDRAW_MANAGER;

    /// @notice 10 ** vault.decimals(). Shares carry a decimals offset (20 where the asset
    ///         has 18), so a floor expressed per 1e18 shares would be wrong by 100x.
    uint256 public immutable SHARE_UNIT;

    /// @notice What this router has already settled for an owner, per request window.
    struct Settlement {
        uint256 window; // endWithdrawWindowTimestamp the settlement belongs to
        uint256 claimed; // shares settled against that request so far
    }

    mapping(address owner => Settlement) public settlement;

    /// @notice Optional per-owner floor, in asset units per whole share. 0 = none.
    mapping(address owner => uint256 floor) public minAssetsPerShare;

    event Claimed(address indexed owner, address indexed caller, uint256 shares, uint256 assets);
    event MinAssetsPerShareSet(address indexed owner, uint256 minAssetsPerShare);

    error ZeroAddress();
    error VaultMismatch(address expected, address actual);
    error NothingToClaim(address owner);
    error AlreadySettled(address owner, uint256 window);
    error BelowFloor(uint256 assetsPerShare, uint256 floor);
    error Reentrancy();

    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address vault_, address withdrawManager_) {
        if (vault_ == address(0) || withdrawManager_ == address(0)) revert ZeroAddress();

        // A mismatched pair would let the router read one vault's requests while
        // redeeming another's shares. Refuse to exist in that state.
        address declared = IWithdrawManager(withdrawManager_).getPlasmaVaultAddress();
        if (declared != vault_) revert VaultMismatch(vault_, declared);

        VAULT = IPlasmaVault(vault_);
        WITHDRAW_MANAGER = IWithdrawManager(withdrawManager_);
        SHARE_UNIT = 10 ** IPlasmaVault(vault_).decimals();
    }

    /// @notice Require third-party claims to achieve at least this many asset units per
    ///         whole share. Only ever settable for the caller's own address.
    function setMinAssetsPerShare(uint256 minAssetsPerShare_) external {
        minAssetsPerShare[msg.sender] = minAssetsPerShare_;
        emit MinAssetsPerShareSet(msg.sender, minAssetsPerShare_);
    }

    /// @notice Settle `owner`'s released redemption request, paying `owner`.
    /// @dev Callable by anyone. Settles the smaller of what is left of the request and
    ///      what the vault currently permits.
    function claimFor(address owner) external nonReentrant returns (uint256 assets) {
        if (owner == address(0)) revert ZeroAddress();

        (uint256 requested, uint256 window) = WITHDRAW_MANAGER.requestInfo(owner);
        if (requested == 0) revert NothingToClaim(owner);

        Settlement memory prior = settlement[owner];
        uint256 already = prior.window == window ? prior.claimed : 0;
        if (already >= requested) revert AlreadySettled(owner, window);

        uint256 remaining = requested - already;
        uint256 redeemable = VAULT.maxRedeem(owner);
        uint256 shares = remaining < redeemable ? remaining : redeemable;
        if (shares == 0) revert NothingToClaim(owner);

        // Effects before interaction: the ledger is written first, so a re-entrant
        // redeem cannot see a stale count.
        settlement[owner] = Settlement({window: window, claimed: already + shares});

        // receiver == owner, always. No code path names any other address.
        assets = VAULT.redeem(shares, owner, owner);

        uint256 floor = minAssetsPerShare[owner];
        if (floor != 0 && msg.sender != owner) {
            uint256 rate = (assets * SHARE_UNIT) / shares;
            if (rate < floor) revert BelowFloor(rate, floor);
        }

        emit Claimed(owner, msg.sender, shares, assets);
    }

    /// @notice What `claimFor(owner)` would settle now, and whether it would succeed.
    /// @dev Lets a keeper skip accounts that would revert instead of paying gas to learn.
    function claimable(address owner) external view returns (uint256 shares, bool ready) {
        (uint256 requested, uint256 window) = WITHDRAW_MANAGER.requestInfo(owner);
        if (requested == 0) return (0, false);

        Settlement memory prior = settlement[owner];
        uint256 already = prior.window == window ? prior.claimed : 0;
        if (already >= requested) return (0, false);

        uint256 redeemable = VAULT.maxRedeem(owner);
        uint256 remaining = requested - already;
        shares = remaining < redeemable ? remaining : redeemable;
        ready = shares != 0 && VAULT.allowance(owner, address(this)) >= shares;
    }
}
