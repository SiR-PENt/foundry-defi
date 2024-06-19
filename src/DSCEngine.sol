// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import { DecentralizedStableCoin } from "./DecentralizedStableCoin.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import { OracleLib } from './libraries/OracleLib.sol';
/**
 * @title DSCEngine
 * @author Olasunkanmi Balogun
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algorithmically stable
 * 
 * It is similar to DAI, if DAI had no governance, fees, and was only backed by wETH and wBTC
 * 
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC
 * 
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral
 * @notice This contract is VERY loosely based on the MAKERDAO DSS (DAI) system
 */

contract DSCEngine is ReentrancyGuard {

   /////////////// 
   // Errors ////
   /////////////// 

   error DSCEngine__NeedsMoreThanZero();
   error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
   error DSCEngine__NotAllowedToken();
   error DSCEngine__TransferFailed();
   error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
   error DSCEngine__MintFailed();
   error DSCEngine__HealthFactorOk();
   error DSCEngine__HealthFactorNotImproved();

   /////////////// 
   // Types //
   ///////////////

   using OracleLib for AggregatorV3Interface;

   /////////////// 
   // State Variables //
   ///////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% Overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100; //we want to know what the health factor is with precision.
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;  
   //allowed list of collateral
   mapping(address token => address priceFeed) private s_priceFeeds;   
   
   // track the collateral the user has deposited
   mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; //let's say this is an object whose shape looks like this { user: { token: amount } };
   mapping(address user => uint256 amountDscMinted) private s_DscMinted; // get the amount of DSC minted per user
   address[] private s_collateralTokens;

   DecentralizedStableCoin private immutable i_dsc;

   /////////////// 
   // Events //
   ///////////////

   event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
   event CollateralRedeemed(address indexed redeeemedFrom, address redeemedTo, address indexed token, uint256 amount);
   /////////////// 
   // Modifiers //
   /////////////// 

   modifier moreThanZero(uint256 amount) {
    if(amount == 0) {
        revert DSCEngine__NeedsMoreThanZero();
    }
    _;
   }

   modifier isAllowedToken(address token) {
    if(s_priceFeeds[token] == address(0)) {
        revert DSCEngine__NotAllowedToken();
    }
    _;
   }

   /////////////// 
   // Functions //
   /////////////// 

   
   // when this contract is deployed, we'll deploy it with a list of allowed tokens

   constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
      if(tokenAddresses.length != priceFeedAddresses.length) {
        revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
      }
      // For example ETH/USD, BTC/USD, MKR/USD etc addresses
      for(uint256 i = 0; i < tokenAddresses.length; i++) {
        s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]; //match tokenAddress to respective priceFeed address
        s_collateralTokens.push(tokenAddresses[i]); //copy each tokens to the s_collateralTokens variable to make it available throughout this contract 
      }
      i_dsc = DecentralizedStableCoin(dscAddress);  
   }

   /////////////// 
   // External Functions //
   /////////////// 

   /**
    * 
    * @param tokenCollateralAddress The address of the token to deposit a collateral
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The ammount of decentralized stablecoin to mint
    * @notice this function will deposit your collateral and mint DSC in one transaction
    */

   function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external { // deposit collateral(DAI/BTC) and mint dsc
       depositCollateral(tokenCollateralAddress, amountCollateral);
       mintDsc(amountDscToMint);
   } 

   /**
    * @notice follows CEI pattern (Checks, Effects, Interactions)
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    */
   
   //reentrant is one the common attacks in web3
   function depositCollateral(address tokenCollateralAddress, uint amountCollateral) public moreThanZero(amountCollateral) isAllowedToken(tokenCollateralAddress) nonReentrant {
     s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral; // so here we are adding amountCollateral to the tokenCollateralAddress of the user
     emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral); // emit after updating state
     // transfer the tokens
     bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral); // here, we are transferring "amountCollateral" from msg.sender to "this" address
     if(!success) {
        revert DSCEngine__TransferFailed();
     }
   }

   /**
    * @param tokenCollateralAddress  The collateral address to redeem
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of DSC to burn
    * This function burns DSC and redeems underlying collateral in one transaction
    */

   function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external { // deposit DSC and get your collateral back
      burnDsc(amountDscToBurn);
      redeemCollateral(tokenCollateralAddress, amountCollateral);
      // redeem collateral already checks health factor
   }

   //in order to redeem collateral:
   // 1. health factor must be over 1 after collateral pulled 
   
   function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
      s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral; // remove the amount of collateral deposited by this user
      emit CollateralRedeemed(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
      // _calculateHealthFactorAfter();
      // THIS IS HOW YOU MOVE TOKENS FROM ONE ACCOUNT TO ANOTHER
      bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
      if(!success) {
         revert DSCEngine__TransferFailed();
      }
      _revertIfHealthFactorIsBroken(msg.sender);
   }

   /**
    * @notice follows CEI
    * @param amountDscToMint The amount of Dsc to mint
    * @notice they must have more collateral value than the minimum threshold 
    */

   function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
      s_DscMinted[msg.sender] += amountDscToMint;
      //if they mint too much
      _revertIfHealthFactorIsBroken(msg.sender);
      // actually mint the Dsc
      bool minted = i_dsc.mint(msg.sender, amountDscToMint);
      if(!minted) {
         revert DSCEngine__MintFailed();
      }
   }
   
   function burnDsc(uint256 amount) public moreThanZero(amount) {
      _burnDsc(msg.sender, msg.sender, amount);
      _revertIfHealthFactorIsBroken(msg.sender); // though it might not hit
   }

   // If we do start nearing collateralization, we need someone to liquidate positions

   // $100 ETH backing $50 DSC
   // $20 ETH back $50 DSC <- DSC isn't worth $1: which is the peg

   // $75 backing $50 DSC
   // Liquidator take $75 backing and burns off the $50 DSC
   
   // If someone is almost undrcollateralized, we want to pay someone to liquidate them

   /**
    * @param collateral The erc20 collateral address to liquidate from the user
    * @param user The user should have broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover The amount of DSC you want to burn to improve the users health factor
    * @notice You can partially liquidate a user
    * @notice You will get a liquidation bonus for taking users funds
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
    * @notice A known bug would be if the prtocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidator
    * For example, if the price of the collateral plummeted before abyone could be liquidated
    * 
    * Follows CEI: Checks, Effects, Interactions
    */

   function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
       // need to first check the health factor of the user
       uint256 startingUserHealthFactor = _healthFactor(user);
       if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
          revert DSCEngine__HealthFactorOk();
       }
       // We want to burn their DSC "debt"
       // And take their collateral 
       // For example; Bad User: $140 ETH, $100 DSC
       // debtToCover = $100 DSC
       // $100 of DSC == How much is $100 dsc in eth?
       // assume
       //   $2000 -----> 1eth
       //            *
       //   $100dsc -------> xEth = 2000XEth = 100eth
       //  
       uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
       //  we also want to give them a bonus for liquidating. So, we'll give them a 10% bonus
       // So we are giving the liquidator $110 of WETH for 100 DSC
       // We should implement a feature to liquidate in the event the protocol is insolvent
       // Amd sweep extra amounts into a treasury

       uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; // this also translates to 10/100 which is 10%
       uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
       _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem );
       _burnDsc(user, msg.sender, debtToCover);

       // check if the health factor of the liquidatee was improved
       uint256 endingUserHealthFactor = _healthFactor(user);
       if(endingUserHealthFactor <= startingUserHealthFactor) {
         revert DSCEngine__HealthFactorNotImproved();
       }
      //  also revert if this process messes up the liquidator's health factor
      _revertIfHealthFactorIsBroken(msg.sender);
   }

   function getHealthFactor() external view {}

    /////////////// 
   // Private & Internal View Functions //
   /////////////// 

   function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
       totalDscMinted = s_DscMinted[user];
       collateralValueInUsd = getAccountCollateralValue(user);  
    }
   /**
    * Returns how close to liquidation a user is
    * If a useer goes below 1, then they can get liquidated
    */

   function _healthFactor(address user) private view returns (uint256) {
    // total DSC minted
    // total collateral VALUE
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
    uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; // we want to be overcollateralized so we multiply by 50.
    // we divide by 100 to have precision
    return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
   }

    //1. Check health factor (do they have enough collateral?)
    //2. Revert if they don't
   function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR) {
          revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
   }

   /////////////// 
   // Private & External View Functions //
   ///////////////
   function _redeemCollateral( address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
      s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral; // remove the amount of collateral deposited by this user
      emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
      // _calculateHealthFactorAfter();
      // THIS IS HOW YOU MOVE TOKENS FROM ONE ACCOUNT TO ANOTHER
      bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
      if(!success) {
         revert DSCEngine__TransferFailed();
      } 
   }

   /**
    * @dev Low-level internal function, do not call unless the function calling it is checking for health factors being broken
    */

   function _burnDsc( address onBehalfOf, address dscFrom, uint256 amountDscToBurn ) private {
      s_DscMinted[onBehalfOf] -= amountDscToBurn;
      bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
      // This conditional is hypothetically unreachable because transferFrom has its own error msg
      if(!success) {
         revert DSCEngine__TransferFailed();
      }
      i_dsc.burn(amountDscToBurn);
   }

   function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
      // price of ETH (token)
      AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
      (, int256 price,,, ) = priceFeed.staleCheckLatestRoundData(); // note that price always comes in 8dp
      return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
   }

   function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
    // loop through collateral token, get the amount they have deposited, and map it to the price
    // to get the USD value
    
    for(uint256 i = 0; i < s_collateralTokens.length; i++) {
        address token = s_collateralTokens[i];
        uint256 amount = s_collateralDeposited[user][token]; 
        totalCollateralValueInUsd += getUsdValue(token, amount);
    }

    return totalCollateralValueInUsd;
   } 

   function getUsdValue(address token, uint256 amount) public view returns(uint256) {
       AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]); // get the priceFeed of the token via chainlink
       (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
       return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount)/ PRECISION;
   }

   function getAccountInformation(address user) external view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
      (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
   }

   function getCollateralTokens() external view returns (address[] memory) {
      return s_collateralTokens;
   }

   function getCollateralBalanceOfUser(address user, address token) external view returns (uint256){
      return s_collateralDeposited[user][token];
   }

   function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
   }

}
