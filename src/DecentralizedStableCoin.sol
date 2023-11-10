//SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
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
// internal & private view & pure functions
// external & public view & pure functions

pragma solidity ^0.8.19;

//install: forge install OpenZeppelin/openzeppelin-contracts --no-commit
import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecnetralizedStableCoin
 * @author Norbert Orgovan
 *
 * Collateral: Exogenous (ETH ß BTC)
 * Minting: Algorithmic (decentralized)
 * Relative Stability: Pegged to USD
 *
 * This is the contract meant to be governed by DSCEngine. This contract is just the ERC20 implementation of our stablecoin system.
 * The logic is going to be in a separate contract.
 */

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    //is ERC20Burnable: we want to have the burn function so we can burn to maintain the peg price
    //is Ownable: we want this to 100% controlled by logic

    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        //Ownable contract has the onlyOwner modifier

        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }

        //super keyword says: use the burn function of the parent class, which is ERC20Burnable here
        //we need this since we are overriding the burn function, we are saying we do the custom stuff and then call the regular, original burn function
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress(); //we dont want ppl to accidently mint to the 0 address
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        _mint(_to, _amount); //we are not overrriding the function so we can just simly call it as-is, no need for super keyword
        return true;
    }
}
