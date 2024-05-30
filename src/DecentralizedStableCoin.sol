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

import { ERC20Burnable, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
//the ERC20Burnable contract is an ERC20 which is why we can import ERC20 from it as well
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/*
* @title DecentralizedStableCoin
* @author Olasunkanmi Balogun
* Collateral: Exogenous (ETH & BTC)
* Minting: Algorithmic
* Relative Stability: Pegged to USD
*
* This is the contract meant to be governed by DSCEngine. This contract is just the ERC20 implementation of our stablecoin system.
*/

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
//ERC20Burnable has a burn function that will help us maintain the peg price when we burn tokens
  error DecentralizedStableCoin__MustBeMoreThanZero();
  error DecentralizedStableCoin__BurnAmountExceedsBalance();
  error DecentralizedStableCoin__NotZeroAddress();


  constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}     

  function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if(_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        if(balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount); //the super keyword says it should utilize the original burn function
  }

  function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
    if(_to == address(0)) {
        revert DecentralizedStableCoin__NotZeroAddress();// do not send to the zeroeth address
    }
    if(_amount <= 0) {
        revert DecentralizedStableCoin__MustBeMoreThanZero();
    }
    _mint(_to, _amount); // we can call this directly, because we didnt initially override the _mint function
    return true;
  }
}