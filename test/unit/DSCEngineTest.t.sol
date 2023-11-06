// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address weth;
    //address btcUsdPriceFeed;
    //address wbtc;

    address public USER = makeAddr("user"); //for pranks
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        //has to be spelled exaclty like this, ie. setUp
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ////////////////////////
    //// Price tests ///////
    ////////////////////////

    function testGetUsdValue() public {
        //forge test --mt testRevertsIfCollateralZero
        uint256 ethAmount = 15e18; //15 ETH
        //15e18 / 2000/ETH = 30 000 e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    ////////////////////////////////////
    //// depositCollateral tests ///////
    ////////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        /*The reason you add (weth) after ERC20Mock is to create an instance of the ERC20Mock contract using the address of a specific ERC-20 token (weth). In Solidity, when you want to interact with an external contract, you typically need to create an instance of that contract by providing its address. This allows your contract to access and interact with the external contract's functions and state variables.
        In this context, ERC20Mock is a contract type, and you need to create an instance of it that is connected to the weth contract. This instance is what you use to call the approve function on the weth contract.*/
        //ERC20Mock(weth) creates an instance of the ERC20Mock contract type.
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector); //what about selectors? review https://www.youtube.com/watch?v=sas02qSFZ74&t=36855s
        engine.depositCollateral(weth, 0);
        vm.stopPrank;
    }
}
