// SPDX-License-Identifier: MIT

// Have our invariant aka properties (that must hold)

//  What are our invariants?

// 1. The total supply of DSC should be less than the total value of collateral

// 2. Getter view functions should never revert <- evergreen invariant

pragma solidity ^0.8.18;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { DeployDSC } from "../../script/DeployDSC.s.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OpenInvariantsTest is StdInvariant, Test {
   DeployDSC deployer;
   DSCEngine dsce;
   DecentralizedStableCoin dsc;
   HelperConfig config;
   address weth;
   address wbtc;

   function setUp() external {
       deployer = new DeployDSC();
       (dsc, dsce, config) = deployer.run();
       ( ,, weth, wbtc, ) = config.activeNetworkConfig();
       targetContract(address(dsce));
   }

   function invariant_openProtocolMustHaveMoreValueThanTotalSupply() public view {
       // get the value of all the collateral in the protocol
       // compare it to all the debt (dsc)

       uint256 totalSupply = dsc.totalSupply(); // totalSupply of stable coin minted, I think
       uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce)); // total supply of weth deposited
       uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce)); // total supply of wbtc deposited
       
       uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
       uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

       assert(wethValue + wbtcValue >= totalSupply); // since the deposit must always be greater than minted
   }
}