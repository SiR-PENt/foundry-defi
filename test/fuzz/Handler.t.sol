// SPDX-License-Identifier: MIT

// Handler is going to narrow down the way we call functions

pragma solidity ^0.8.18;
import { Test, console } from "forge-std/Test.sol";
import { DecentralizedStableCoin } from '../../src/DecentralizedStableCoin.sol';
import { DSCEngine } from '../../src/DSCEngine.sol';
import { ERC20Mock } from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import { MockV3Aggregator } from '../mocks/MockV3Aggregator.sol';

contract Handler is Test {

    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    ERC20Mock weth;
    ERC20Mock wbtc;

    // check if mint is being called
    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; // the max uint96 value. 
    // we are not using the max uint256 because after we get to its max number, it reverts if you we attempt to increment

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {

        if(usersWithCollateralDeposited.length == 0) {
            return;
        }

        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        
        if(maxDscToMint < 0) {
            return;
        }

        amount = bound(amount, 0, uint256(maxDscToMint));

        if (amount == 0) {
            return;
        }

        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    // deposit collateral 
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        
        // this will always break because the depositor did not first approve that the money be withdrawn from his/her acct.
        // the next snippet of code prevents this bug

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral); // why are we minting here?
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank(); 
        usersWithCollateralDeposited.push(msg.sender);   
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
      ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
      uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));
      amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
      // because the collateral cannot be equal to 0
      if (amountCollateral == 0) {
        return;
      }
      dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    function updateCollateralPrice(uint96 newPrice) public {
        int256 newPriceInt = int256(uint256(newPrice));
        ethUsdPriceFeed.updateAnswer(newPriceInt); 
    }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if(collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
