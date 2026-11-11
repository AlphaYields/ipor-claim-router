# ipor-claim-router

A permissionless settlement contract for IPOR Fusion redemption requests. Once a user's
queued redemption is released, **anyone** can settle it for them — and the assets can
only ever go to the user.

This exists so depositors do not have to come back and claim.

---

## The security model, in one line

**The receiver is hardcoded to the owner.** The contract never names a destination, never
holds funds, has no admin and no upgrade path.

```solidity
assets = VAULT.redeem(shares, owner, owner);   // no code path names any other address
```

A compromised keeper can call `claimFor` and nothing else. The worst it can do is pay a
user their own money.

## Three properties that make a standing approval safe

**1. Request-bound.** A claim settles at most what the WithdrawManager says the owner has
queued. An approval on its own redeems nothing — a user who has made no request cannot be
redeemed out of the vault by anyone.

**2. Settled once per request.** IPOR's WithdrawManager does **not** clear a request after
redemption. `requestInfo` keeps reporting the original shares, and the vault will redeem
against it again while idle liquidity lasts. Unguarded, repeated calls would drain an
approving user's entire balance — this was found and reproduced on a fork during
development. The router therefore keeps its own per-owner ledger, keyed on the request's
withdraw window, and never settles more than the request in total. Partial fills are
tracked so a half-filled request can be finished later rather than burned.

**3. Owner-set floor.** An owner may require a minimum assets-per-share before a third
party settles for them, so a caller cannot pick a moment when the share price is
temporarily depressed. An owner is never subject to their own floor.

Everything else — timing, release, the withdraw window, accounting — stays the
protocol's. This contract re-implements none of it.

## Interface

```solidity
function claimFor(address owner) external returns (uint256 assets);
function claimable(address owner) external view returns (uint256 shares, bool ready);
function setMinAssetsPerShare(uint256 minAssetsPerShare) external;
```

`minAssetsPerShare` is in **asset units per whole share**. Fusion shares carry a decimals
offset (20 where the asset has 18), so the contract scales by `SHARE_UNIT = 10**decimals`
rather than a bare `1e18` — a floor written against `1e18` would be wrong by 100×.

## Flow

```
1. user   -> WithdrawManager.requestShares(n)
             PlasmaVault.approve(router, n)          <- one extra UI step
2. keeper -> WithdrawManager.releaseFunds(...)       <- already the operator's job
3. anyone -> ClaimRouter.claimFor(user)              <- the new step; assets land with the user
```

Nothing on the vault changes. No role grant, no fuse, no governance action, no timelock.
The router is just another address holding an ERC-20 allowance.

## Build and test

```bash
forge build
KATANA_RPC=<rpc> forge test
```

Tests fork Katana and run against the **live ayKAT vault and WithdrawManager** — the
protocol is not mocked. 26 tests, including 512 fuzz runs over arbitrary callers.

> Foundry's OP-stack detection panics against Katana's public RPC. Fork a local node
> first (`anvil --fork-url …`) and point `KATANA_RPC` at it.

## Deploy

```bash
VAULT=0x94Ff40197900a6Ea5D9D63C691d89e70aC1343d6 \
WITHDRAW_MANAGER=0x25B2f567CF4141AE62035B8b062a51C2B562A4E2 \
forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --interactives 1
```

One deployment per vault. The constructor rejects a manager that does not point back at
the vault, so a mismatched pair cannot exist.

## What this does not solve

The user still signs an approval. Removing that entirely needs a `claimFor` inside the
WithdrawManager, or an ERC-7540 operator model — both of which touch IPOR's audited vault,
because the allowance check lives there.
