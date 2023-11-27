// SPDX-License-Identifier: MIT

//handler-based: more sophistated stateful fuzzing: we call functions in specific ways, so that we have a higher likelyhood of calling function in orders that we want.
//narrows down the way how functions are called
// how all this works: https://chat.openai.com/c/fbfd1da8-75b2-4a07-a962-e5e4b1580ad0

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
//import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
//Handler could handler not only DSCEngine, but also any other contract that we interact with.
//PriceFeed is one of the most important. So we are gonna include pricefeed updates in our protocol
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled; //ghost variable. Solidity automatically creates a getter for public vars https://chat.openai.com/c/ebbbeb1f-3849-4491-9e57-213d5bc123cc
    address[] public userWithCollateralDeposited; //for narrowing down the fuzz. Fuzz calls the functions in a random order, with random vars, and with rnd addresses. However, one can only mint if one has already deposited.
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; // max value for uint96. We dont want to use uin256 to absolutely max out, since later on we might want to increase the deposit and then we would get an overflow

    //this contract has to know about the engine and the dsc that it is going to make calls to, so constructor should contain this info
    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        engine = _dscEngine;
        dsc = _dsc;
        address[] memory collateralTokens = engine.getCollateralTokenAddresses();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(weth)));
    }

    // redeem collateral: only call redeem when there is collateral to redeem
    // in the handler, whatever params we have, are gonna be randomized: random collateralSeed, random amountCollateral
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        //if we have the following, we are still depositing a random collateral, but it will surely be a valid collateral,
        //so we are more likely to pass a random transaction that will actually go thorough
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed); //narrow down
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE); //narrow down. Bound = value will stay between defined limits. (But with narrowing down one should be careful to not narrow things so much that we end of not testing an edge case that might point ot an issue.)

        vm.startPrank(msg.sender); //why is it needed here?
        collateral.mint(msg.sender, amountCollateral); //narrow it down. Would always fail without deposited collateral, so we give the msg.sender collateral
        collateral.approve(address(engine), amountCollateral); //narrow it down. Would always fail without approval

        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        // note: this will double push, one address can appear multiple times
        userWithCollateralDeposited.push(msg.sender);
    }

    //this seed thing is used when we want to narrow down of the randomization of a var in a way
    //that a value will be randomly selected from a predefine set (or selection) of value
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (userWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length]; // narrow it down to addresses who already deposited collateral

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted); //this is the max due to the overcollaterization requirement. Here we enforce that it wont be negative
        if (maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint)); //we need 0 here as the MAX_DEPOSIT_SIZE might be 0
        if (amount == 0) {
            return;
        }

        vm.startPrank(sender); //and not msg.sender
        engine.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    //this fails, and it is a known issue: https://github.com/Cyfrin/foundry-defi-stablecoin-f23/issues/30
    //adding a vm.prank(msg.sender) line befoe the if condition fixes the issue - but why?
    //But even with this, the health factor can be broken, resulting in a failed test
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem); //we need to keep 0 in here, since maxCollateralToRedeem can sometimes be 0
        if (amountCollateral == 0) {
            //but if amountCollateral is 0, we will fail, so we need this if
            return;
        }

        vm.prank(msg.sender); //Patrick does not have this line - and without it, the test fails
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    //if the price too quickly, i.e. plummets hard in a single block, we are screwed.
    //This breaks our invariant test suite.
    /*function updateCollateralPrice(uint96 newPrice) public {
        //uint96 so we wont get too high random number
        int256 newPriceInt = int256(uint256(newPrice)); //priceFeeds take in256
        ethUsdPriceFeed.updateAnswer(newPriceInt);
    }*/
}
