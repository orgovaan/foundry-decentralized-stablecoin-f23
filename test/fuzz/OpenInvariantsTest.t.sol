// SPDX-License-Identifier: MIT

// Has our invariants (aka props of the system that should always hold)
// What are ourinvariants?
// 1. The total supply of the should be less than the total value of collateral
// 2. Getter view functions should never revert :: evergreen invariant

// As on Open invariant test, it has a poor performance, e.g. calls: 16384, reverts: 12859
// E.g. it uses random addresses that are not approved / did not deopisti anytings, etc.

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol"; // for fuzz testing
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

pragma solidity ^0.8.19;

contract OpenInvariantTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
        // define the target contract for the fuzz test
        targetContract(address(dsc));
    }

    function invariant_procolMustHaveMoreValueThanTotalSupply() public view {
        // get tge value of all the collateral in the protocol
        // compare it to all the debt (DSC)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value: ", wethValue);
        console.log("wbtc value: ", wbtcValue);
        console.log("total supply: ", totalSupply);

        assert(wethValue + wbtcValue >= totalSupply);
    }
}
