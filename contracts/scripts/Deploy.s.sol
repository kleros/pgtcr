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
        
        // wxdai
        address W_NATIVE = 0x4ED2addA46A7e24d06CE1BaACC6a4b69c1FAB404;

        PermanentGTCR template = new PermanentGTCR(W_NATIVE);
        PermanentGTCRFactory factory = new PermanentGTCRFactory(address(template));

        vm.stopBroadcast();

        console.log("PGTCR template deployed at:", address(template));
        console.log("PGTCR factory deployed at:", address(factory));
    }
}
