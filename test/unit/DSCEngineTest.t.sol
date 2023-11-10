// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockDscFailedMint} from "../mocks/MockDscFailedMint.sol";
import {MockWethFailedTransferFrom} from "../mocks/MockWethFailedTransferFrom.sol";
import {MockWethFailedTransfer} from "../mocks/MockWethFailedTransfer.sol";
import "forge-std/console.sol"; //for logging

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;

    address public USER = makeAddr("user"); //for pranks
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    //these have default values but for testing purposes we sometimes change them
    uint256 public amountToMint = 100 ether;
    uint256 public constant amountCollateral = 10 ether; //this is only the amount. Price is set at $2000 a piece

    ////////////////////////////
    ////// Modifiers ///////////
    ////////////////////////////

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral); //in order to deposit weth, we need to approve
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _; //execute the rest of the code
    }

    modifier depositiedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral); //in order to deposit weth, we need to approve
        engine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    ////////////////////////////
    ////// Setup /// ///////////
    ////////////////////////////

    function setUp() public {
        //has to be spelled exaclty like this, ie. setUp
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /////////////////////////////
    //// Constructor tests //////
    ////////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////////
    //// Price tests ///////
    ////////////////////////

    // @notice The ETH price of $2000 (2000e8) is defined in the HelperConfig file (for tests on Anvil).
    function testGetUsdValue() public {
        //forge test --mt testRevertsIfCollateralZero
        uint256 ethAmount = 15e18; //15 ETH
        //15e18 / 2000/ETH = 30 000 e18
        uint256 expectedUsd = 30000e18; //hardcoded, does not work on sepolia where we have the real price
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    // @notice The ETH price of $2000 (2000e8) is defined in the HelperConfig file (for tests on Anvil).
    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        //100 ether / 2000 = 0.05 ether
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }

    ////////////////////////////////////
    //// depositCollateral tests ///////
    ////////////////////////////////////

    /*
    * @notice This function needs its own setup.
    * The MockFailedMintDsc contract has a hardcoded "false" return value: 
    * The DSCEngine contract checks the return value of the mint function to determine success, 
    * and it will always assume the minting failed due to the hardcoded return false; statement.
    */
    function testRevertsIfDepositFails() public {
        // Arrange -Setup
        //This mock contract overwrites the transferFrom function defined in ERC20.sol, and hardcodes a "false" return value
        MockWethFailedTransferFrom mockWeth = new MockWethFailedTransferFrom();
        tokenAddresses = [address(mockWeth)];
        priceFeedAddresses = [ethUsdPriceFeed];

        //tokenAddresses[] has a mock item (mockWeth) so we need another engine
        DSCEngine mockWethDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        //not needed, as dsc is not minted here
        /*vm.prank(address(engine));                
        dsc.transferOwnership(address(mockWethDscEngine));*/

        // Setup user
        mockWeth.mint(USER, amountCollateral); //give user some starting collateral

        // Act
        vm.startPrank(USER);
        ERC20Mock(address(mockWeth)).approve(address(mockWethDscEngine), amountCollateral); //in order to deposit weth, we need to approve

        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockWethDscEngine.depositCollateral(address(mockWeth), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        /*The reason you add (weth) after ERC20Mock is to create an instance of the ERC20Mock contract using the address of a specific ERC-20 token (weth). In Solidity, when you want to interact with an external contract, you typically need to create an instance of that contract by providing its address. This allows your contract to access and interact with the external contract's functions and state variables.
        In this context, ERC20Mock is a contract type, and you need to create an instance of it that is connected to the weth contract. This instance is what you use to call the approve function on the weth contract.*/
        //ERC20Mock(weth) creates an instance of the ERC20Mock contract type.
        ERC20Mock(weth).approve(address(engine), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector); //what about selectors? review https://www.youtube.com/watch?v=sas02qSFZ74&t=36855s. Needed, as: this ecpects a selector.
        engine.depositCollateral(weth, 0); //When you call a function on a contract instance, Solidity automatically includes the correct function selector
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("RAN", "RAN", USER, 100e18);
        ERC20Mock(randomToken).mint(USER, STARTING_ERC20_BALANCE);

        vm.startPrank(USER);
        ERC20Mock(randomToken).approve(address(engine), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(randomToken), amountCollateral);

        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        //collateralDepositied modifier

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedDscMinted = 0; //depositied collateral but never minted DSC
        uint256 expectedDepositAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd); //will be 10 e18, i.e. 10 ether

        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(amountCollateral, expectedDepositAmount);
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        // Deposit done via the modifier. Success of the deposition is "tested" implicitly: if it is not a success, the function will revert with error
        // Now we need to test that the user did not mint any DSC.
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    //we have a very similar test function, but that one calls mintDsc, and not depositCollateralAndMintDsc after vm.expectRevert.
    function testRevertsIfMintedAmountBreaksHealhFactorWhenDepositCollateralAndMintIsCalled() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData(); //price of ETH

        //Attempting to mint the exact same $ emount as we deposited - which surely resoults in a broken health factor
        amountToMint =
            (amountCollateral * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();

        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, amountCollateral));

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testCanMintCallingDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral); //approval for weth
        engine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = ERC20Mock(address(dsc)).balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    //////////////////////
    /// Mint tests ///////
    //////////////////////

    function testRevertsIfMintAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    function testCanMintDscCallingMint() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(amountToMint, userBalance);
    }

    //we have a very similar test function, but that one calls depositCollateralAndMintDsc after vm.expectRevert, and not mintDsc.
    function testRevertsIfMintAmountBreaksHealthFactorWhenMintIsCalled() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        //Attempting to mint the exact same $ emount as we deposited - which surely resoults in a broken health factor
        amountToMint =
            (amountCollateral * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();

        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, amountCollateral));

        //(, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        //assertEq(collateralValueInUsd, engine.getUsdValue(weth, amountCollateral));  ==  TRUE

        vm.startPrank(USER);
        //abi.encodeWIthSelector is a function that allows you to encode arguments along with a specified function selector.
        //Typically used when you need to make a low-level call to another contract with specific data. Here the specific data is the expectedHealthFactor.
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    /*
    * @notice This function needs its own setup.
    * The MockFailedMintDsc contract has a hardcoded "false" return value: 
    * The DSCEngine contract checks the return value of the mint function to determine success, 
    * and it will always assume the minting failed due to the hardcoded return false; statement.
    */
    function testRevertsIfMintFails() public {
        ///// arrange - SETUP /////
        MockDscFailedMint mockDsc = new MockDscFailedMint();

        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];

        DSCEngine mockDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDscEngine));
        // end of setup

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDscEngine), amountCollateral); //in order to deposit weth, we need to approve

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    //////////////////////
    /// burn tests ///////
    //////////////////////

    function testUserCanBurnDsc() public depositiedCollateralAndMintedDsc {
        uint256 amountToBurn = amountToMint;

        vm.startPrank(USER);
        dsc.approve(address(engine), amountToBurn);
        //console.log(dsc.balanceOf(address(dsc))); //just for logging
        engine.burnDsc(amountToBurn);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    /*
    * This does not work like this, as we would run into an arithmetic error. When amountToBurn > s_DscMinted. s_DscMinted ,a uint256 var would go below 0.
    function testRevertsIfBurnAmountExceedsBalance() public depositiedCollateralAndMintedDsc {
        uint256 amountToBurn = amountToMint * 10;

        vm.startPrank(USER);
        dsc.approve(address(engine), amountToBurn);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        engine.burnDsc(amountToBurn);
        vm.stopPrank();
    }*/

    //Here we are relying on Solidity on throwing an error when amountToBurn > s_DscMinted. s_DscMinted would go below 0, but it is a uint256, so Solidity will throw an underflow error
    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnDsc(1);
    }

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral); //dont think this is necessary. Works without it.
        engine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint); //dont think this is necessary. Works without it
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateral Tests ////////
    //////////////////////////////////

    //This function needs its own setup
    function testRevertsIfTransferFails() public {
        // Setup - Arrange
        MockWethFailedTransfer mockWethFailedTransfer = new MockWethFailedTransfer();
        //need new engine for new collateral
        tokenAddresses = [address(mockWethFailedTransfer)];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        //mockWethFailedTransfer.transferOwnership(address(mockEngine)); dont think this is needed

        // Setup user
        vm.startPrank(USER);
        mockWethFailedTransfer.mint(USER, amountCollateral); //give user collateral that he can deposit
        mockWethFailedTransfer.approve(address(mockEngine), amountCollateral); //approve moving mockWeth
        mockEngine.depositCollateral(address(mockWethFailedTransfer), amountCollateral); //deposit
        // Act
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockEngine.redeemCollateral(address(mockWethFailedTransfer), amountCollateral);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public depositedCollateral {
        console.log(ERC20Mock(weth).balanceOf(USER)); //just checking, should be 0 after depositing, before withdrawing
        vm.startPrank(USER);
        engine.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, amountCollateral);
    }
}
