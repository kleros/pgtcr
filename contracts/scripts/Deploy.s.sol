//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import {PermanentGTCR} from "../src/PermanentGTCR.sol";
import {PermanentGTCRFactory} from "../src/PermanentGTCRFactory.sol";

contract Deploy is Script {
    function run() external {
        // Start broadcasting a transaction with the provided private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        // sepolia weth
        address W_NATIVE = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

        PermanentGTCR template = new PermanentGTCR(W_NATIVE);
        PermanentGTCRFactory factory = new PermanentGTCRFactory(address(template));

        vm.stopBroadcast();

        console.log("PGTCR template deployed at:", address(template));
        console.log("PGTCR factory deployed at:", address(factory));
    }
}
