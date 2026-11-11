// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ClaimRouter} from "../src/ClaimRouter.sol";

/// VAULT=0x... WITHDRAW_MANAGER=0x... forge script script/Deploy.s.sol \
///   --rpc-url $RPC --broadcast --interactives 1
///
/// The constructor cross-checks that the manager points back at the vault, so a
/// mismatched pair cannot be deployed.
contract Deploy is Script {
    function run() external returns (ClaimRouter router) {
        address vault = vm.envAddress("VAULT");
        address wm = vm.envAddress("WITHDRAW_MANAGER");

        vm.startBroadcast();
        router = new ClaimRouter(vault, wm);
        vm.stopBroadcast();

        console2.log("ClaimRouter   ", address(router));
        console2.log("  VAULT       ", address(router.VAULT()));
        console2.log("  WITHDRAW_MGR", address(router.WITHDRAW_MANAGER()));
        console2.log("  SHARE_UNIT  ", router.SHARE_UNIT());
    }
}
