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
import {MockMoreDebtDsc} from "../mocks/MockMoreDebtDsc.sol";
import {console} from "forge-std/console.sol"; //for logging

contract DSCEngineTest is Test {
    //the following event is 100% from DSCEngine.sol. We need it here otherwise it would not be accessible.
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated

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

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

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

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice = 18e8; // Crashing the price. 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(USER);

        ERC20Mock(weth).mint(liquidator, collateralToCover); //Gives collateral balance to liquidator. collatralToCover is 20 ether

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover); // deposits ALL his weth
        engine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint); //liquidator mints after prices crashed
        dsc.approve(address(engine), amountToMint);
        engine.liquidate(weth, USER, amountToMint); //covering the USER's whole debt
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

    function testCanRedeemDepositedCollateralCallingRedeemCollateral() public depositedCollateral {
        console.log(ERC20Mock(weth).balanceOf(USER)); //just checking, should be 0 after depositing, before withdrawing
        vm.startPrank(USER);
        engine.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, amountCollateral);
    }

    //Cyfrin version looks unneccesarily complex
    function testRevertIfRedeemAmountIsZero() public depositedCollateral {
        //collateral depositied via the modifier
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    //??? https://chat.openai.com/c/86926ddb-d3e0-4a09-89f5-7e76bb9a9083
    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        emit CollateralRedeemed(USER, USER, weth, amountCollateral); //manual emit. According to chatGPT, not needed. But it can be used to compare.
        vm.startPrank(USER);
        vm.expectEmit(true, true, true, true, address(engine));

        engine.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositiedCollateralAndMintedDsc {
        // deposit and mint via the modifier
        vm.startPrank(USER);
        dsc.approve(address(engine), amountToMint); //the modifier contains approval only for weth. However, this is not really needed as it will revert sooneer than attempting to trasnfer DSC out from the user
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateralForDsc(weth, amountCollateral, 0);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateralCallingRedeemCollateralForDsc() public depositiedCollateralAndMintedDsc {
        // deposited collateral and minted dsc via the modifier
        vm.startPrank(USER);
        dsc.approve(address(engine), amountToMint); //approve dsc to move users dsc
        engine.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, amountCollateral);

        uint256 userBalanceDsc = dsc.balanceOf(USER); //this is from cyfrin, but I think the former is more appropriate
        assertEq(userBalanceDsc, 0);
    }

    ///////////////////////////////////
    // liquidation Tests //
    //////////////////////////////////

    function testCannotLiquidateGoodHealthFactor() public depositiedCollateralAndMintedDsc {
        //deposit and mint done via the modifier
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(engine), amountToMint); //not really neccessary, does not get to that point

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    // this function needs its own setup
    /* @notice The collateral price is set to 0 in the burn function of the MockMoreDebtDsc contract. 
    * This effectively results in a HF = 0 for both the USER and the liquidator, but in a way that by this time
    * - the initial HF of the USER has been checked (and found to be smaller than the MIN, but not 0, so theoretically it could be improved)
    * - the liquidator's HF will be checked later, at the very end of the liquidation function, so the function will revert sooner than that
    * 
    * An alternative, and possibly better option would be
    * 1. USER depositis, mints
    * 2. collateral value falls sharply so that the HF of USER breaks
    * 3. liquidator deposits a ton, mints
    * 4. liquidator attempts to x from the USER's debt, that 
    *   - would improve the USER's HF, but
    *   - while the liquidation function runs, the collateral value crashes hard so that even with the help of the liquidator it would be less than initally
    */
    function testRevertIfLiquidationNotImprovesHealthFactor() public {
        // Arrange - setup mockMoreDebtDsc
        MockMoreDebtDsc mockMoreDebtDsc = new MockMoreDebtDsc(ethUsdPriceFeed);

        // Arrange  - setup the new engine
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockMoreDebtDsc));
        mockMoreDebtDsc.transferOwnership(address(mockEngine));

        // Arrange - setup USER
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockEngine), amountCollateral);
        mockEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Arrange - setup liquidator
        collateralToCover = 1 ether; // c.f. amountCollateral is 10 ether
        ERC20Mock(weth).mint(liquidator, collateralToCover); // give the liquidator an initial collateral balance

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockEngine), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        mockMoreDebtDsc.approve(address(mockEngine), debtToCover); // approval is a prereq for liquidation

        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18. This already destorys the USER's health factor, but later on the price is set to 0
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        /* @notice The price of the collateral is changed one again in the burn function of the MockMoreDebtDsc contract, it is set to 0.
        * If the price is not set to zero (or a low value), then a liquidate function will return with the error messeage "DSCEngine_BreaksHealtFactor()
        * If the price is set to 0 before the liquidation function is called, there will be a devision by 0.
        * If the price is set to a low value before the liquidation function is called, a under/overflow error will occur.
        */
        mockEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    //this is an alternative, and a better version of the function above.
    //set the price in MockMoreDebtDsc.sol to i.e. 1e5, and the HF of the liquidator would be OK, in contrast to the original version
    function testAlternativeRevertIfLiquidationNotImprovesHealthFactor() public {
        // Arrange - setup mockMoreDebtDsc
        MockMoreDebtDsc mockMoreDebtDsc = new MockMoreDebtDsc(ethUsdPriceFeed);

        // Arrange  - setup the new engine
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        DSCEngine mockEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockMoreDebtDsc));
        mockMoreDebtDsc.transferOwnership(address(mockEngine));

        // Arrange - setup USER
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockEngine), amountCollateral);
        mockEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Arrange - drop price
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18. This already destorys the USER's health factor, but later on the price is set to 0
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // Arrange - setup liquidator
        collateralToCover = 1 ether;
        uint256 liquidatorStartingBalance = collateralToCover * 1e25;
        ERC20Mock(weth).mint(liquidator, liquidatorStartingBalance); // give the liquidator a huge initial balance

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockEngine), liquidatorStartingBalance);
        uint256 debtToCover = 10 ether; //i.e. 10 USD

        mockEngine.depositCollateralAndMintDsc(weth, liquidatorStartingBalance, amountToMint);
        mockMoreDebtDsc.approve(address(mockEngine), debtToCover); // approval is a prereq for liquidation

        // Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        //liquidation done via the modifier
        //before liquidation, liquidator Weth balance is 0, since he depositied all his weth to the engine contract
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWethBalance = engine.getTokenAmountFromUsd(weth, amountToMint)
            + (engine.getTokenAmountFromUsd(weth, amountToMint)) / engine.getLiquidationBonus();
        uint256 hardCodedExpected = 6111111111111111110; // 18e8 * 1.1.... Dont know here this is coming from
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWethBalance);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        //liquidation done via the modifier
        uint256 originalDepositValueInUsd = engine.getUsdValue(weth, amountCollateral);

        //calculate how much the user lost
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(weth, amountToMint)
            + (engine.getTokenAmountFromUsd(weth, amountToMint)) / engine.getLiquidationBonus();
        uint256 liquidatedValueInUsd = engine.getUsdValue(weth, amountLiquidated);
        //USER does not have any WETH balance in his address, he has WETH depositied
        (, uint256 expectedCurrentCollateralValueInUsd) = engine.getAccountInformation(USER);

        assertEq(originalDepositValueInUsd - liquidatedValueInUsd, expectedCurrentCollateralValueInUsd);
    }

    function testLiquidatorTakesOnDebt() public liquidated {
        //liquidation done via the modifier
        (uint256 debt,) = engine.getAccountInformation(liquidator);
        assertEq(debt, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        //liquidation done via the modifier
        (uint256 debt,) = engine.getAccountInformation(USER);
        assertEq(debt, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////

    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = engine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testCollateralTokens() public {
        address[] memory collateralTokens = engine.getCollateralTokenAddresses();
        assertEq(collateralTokens[0], weth);
    }

    function testMinHealthFactor() public {
        uint256 minHf = engine.getMinHealthFactor();
        assertEq(minHf, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public {}
}
