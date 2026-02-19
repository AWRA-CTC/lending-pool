// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CreditScore.sol";

contract DeployCreditScore is Script {
    function run() external returns (address) {
        vm.startBroadcast();
        CreditScore credit = new CreditScore();
        vm.stopBroadcast();

        console.log("CreditScore deployed at:", address(credit));
        return address(credit);
    }
}
