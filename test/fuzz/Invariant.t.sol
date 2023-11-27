// SPDX-License-Identifier: MIT

// Has our invariants (aka props of the system that should always hold)
// What are ourinvariants?
// 1. The total supply of the should be less than the total value of collateral
// 2. Getter view functions should never revert :: evergreen invariant

// how all this works: https://chat.openai.com/c/fbfd1da8-75b2-4a07-a962-e5e4b1580ad0

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol"; // for fuzz testing
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

pragma solidity ^0.8.19;

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
        // define the target contract for the fuzz test
        handler = new Handler(engine, dsc);
        targetContract(address(handler)); // instead of targetContract(address(engine));
    }

    function invariant_procolMustHaveMoreValueThanTotalSupply_2() public view {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (DSC)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value: ", wethValue);
        console.log("wbtc value: ", wbtcValue);
        console.log("total supply: ", totalSupply);
        console.log("Times mint called: ", handler.timesMintIsCalled()); //solidity automatically created a getter for this public var https://chat.openai.com/c/ebbbeb1f-3849-4491-9e57-213d5bc123cc

        assert(wethValue + wbtcValue >= totalSupply);
    }

    //this is an evergreen invariant, getters should never revert.
    //This invariant test will call a ton of different functions on the handler, and if any of these revert, the test will fail
    //To ensure we added each and every getter: forge inspect DSCEngine method
    function invariant_gettersShouldNeverRevert() public view {
        engine.getAdditionalFeedPrecision();
        engine.getCollateralTokenAddresses();
        engine.getLiquidationBonus();
        engine.getLiquidationThreshold();
        engine.getMinHealthFactor();
        engine.getPrecision();
        engine.getDscAddress();
        //engine.getTokenAmountFromUsd();
        //engine.getUsdValue();
        //engine.getAccountCollateralValue();
        //engine.getAccountInformation();
        //engine.getCollateralTokenPriceFeed();
        //engine.getHealthFactor();
        //engine.getCollateralBalanceOfUser();
    }
}
