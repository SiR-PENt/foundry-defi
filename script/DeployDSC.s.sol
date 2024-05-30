//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import { Script } from "forge-std/Script.sol";
import { DecentralizedStableCoin } from "../src/DecentralizedStableCoin.sol";
import { DSCEngine } from "../src/DSCEngine.sol";
import { HelperConfig } from './HelperConfig.s.sol';

contract DeployDSC is Script {

    // For the DSCEngine
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth,
        address wbtc, uint256 deployerKey ) = config.activeNetworkConfig();

        tokenAddresses = [ weth, wbtc]; // allowed list of tokens
        priceFeedAddresses = [ wethUsdPriceFeed, wbtcUsdPriceFeed ]; // pricefeed address of the tokens

        vm.startBroadcast(deployerKey); // don't forget the deployerKey
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc)); // we need the dsc here
        // the dsc needs to be owned by the engine. So we'll transfer ownership to the engine
        dsc.transferOwnership(address(engine));
        vm.stopBroadcast();
        return (dsc, engine, config);
    }
}

