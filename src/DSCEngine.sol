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

/**
 * @title DecentralizedStableCoin
 * @author Norbert Orgovan
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the following prpoerties:
 * - Exogeneous collateral
 * - Dollar-pegged
 * - Algorithmically stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC.
 *
 * Our DSC system should always be overcollaterized.
 * At no point should the value of all the collateral <= the $-backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic dor minting
 * and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */

pragma solidity ^0.8.19;

//install: forge install openzeppelin/openzeppelin-contracts@v4.8.3 --no-commit
//import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//install: forge install smartcontractkit/chainlink-brownie-contracts@0.6.1 --no-commit
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

//reentrancy is one of the most common attacts in smart contracts
contract DSCEngine is ReentrancyGuard {
    ////////////////////////////
    ////// Errors ///////////
    ////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////////////////
    ////// State vars //////////
    ////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //means one need to be 200 % overcollaterized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; //this means a 10% bonus

    //mapping(address => bool) private s_tokentoAllowed;    //we could do this, but we already know we are gonna need price feeds. So better:
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; //mapping to a mapping
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc; //immutable

    ////////////////////////////
    ////// Events ///////////
    ////////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTom, address indexed token, uint256 amount
    );
    event BalancesAfterTransfer(uint256 indexed userBalance, uint256 contractBalance);

    ////////////////////////////
    ////// Modifiers ///////////
    ////////////////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _; //execute the rest of the code
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////////////
    ////// Functions ///////////
    ////////////////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress //DSCEngine needs to know about our DSC address
    ) {
        //arrays, the have multiple elements, as different chains will have different addresses
        //USD price feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]; //this is how we set up what tokens are allowed on our platform
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    //// External functions ////
    ////////////////////////////

    /*
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The amount of decentralized stablecoin to mint
    * @notice This function will deposit your collateral and mint DSC in one transaction
    */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 dscToMint)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(dscToMint);
    }

    //Ex: I put in $100 of ETH in collateral, mint $50 of DSC. If ETH price tanks so much that the collateral worth $40 only, that is a huge problem.
    //Treshold to e.g. 150% -> $100 ETH can go only down to $74 ETH
    //If someone pays back your minted DSC, they can have all your collateral for a discount: pay 50 DAI, get $74 worth of ETH.

    /*
     * @notice follows CEI pattern (check, effects, interactions)
     * @param tokenCollateralAddress the address of the token to deposit as collateral
     * @param amountCollateral the amount of collateral to deposit
    */

    event testAddress(address);
    event testBalance(uint256);

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral); //we are modifying state so we should have an event emitted
        //interactions
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral); //this returns a bool
        emit testBalance(IERC20(tokenCollateralAddress).balanceOf(msg.sender));
        //emit testBalance(s_collateralDeposited[msg.sender][tokenCollateralAddress]);
        emit testBalance(IERC20(tokenCollateralAddress).balanceOf(address(this)));

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    //this function combines 2 functions so that this whole thing can be done within one transaction. Children functions need to be public.
    /*
    * @param tokenCollateralAddress The collateral address to redeem
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of DSC to burn
    * This function burns DSC and redeems underlying collateral in one transaction.
    */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks health factor
    }

    //in order to redeem collateral:
    //1. health factor must be over 1 AFTER collateral pulled
    //CEI: checks, effects, interactions. But we need to check sth after the transaction happened
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthfactorIsBroken(msg.sender);
    }

    //1. Check if the collateral value is > DSC amount. This involves: price feeds, checking values...
    //ppl can decide how much they want to mint
    //probably we dont need the nonReentrant modifier
    /*
    * @notice follows CEI
    * @param amountDscToMint The amount of decentralized stablecoins to mint
    * @notice they must have more collateral value than the minimum treshold
    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        //if they minted too much:
        _revertIfHealthfactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint); //mint function returns a bool
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    //This is needed as
    //if ppl are nervous that they have too mucn DSC and not enough collateral, this would be a quick way for them to just burn a part of their DSC
    //Do we need to check if this breaks healh factor? No, because burning DSC is removing debt, but we add a backup nonetheless
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthfactorIsBroken(msg.sender); //backup, probably this will never hit
    }

    //users can call this to kick ppl out of the system who are too close to become undercollaterized
    //If we do start nearing undercollaterization, we need someone to liquidate positions
    //If someone is almost undercollaterized, we will pay you to liquidate them!
    //E.g. $75 backing $50 DSC is lower than treshold -->
    //liquidator take $75 backing and burns off the $50 DSC.
    //nonReentrant as we move tokens around.
    /*
    * @param collateral The erc20 collateral address to liquidate
    * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover The amount of DSC you want to burn to improve the users health factor
    * @notice You can partically liquidate a user
    * @notice You will get a liquidation bonus  for taking the users funds
    * @notice This function working assumes the protocol will be roughly 200% overcollaterized in order for this to work.
    * @notice A known bug would be if the protocol were 100% or less collaterized, then we wouldnt be able to incentivize the liquidators
    * For example, if the price of the collateral plummeted before anyone could be liquidated
    */
    // Follows CEI
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //check whether user has a broken health factor
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        //we want to burn their DSC "debt"
        // ...and take their collateral
        //E.g. bad user $140: $140 ETH, $100 DSC
        // debtToCover: $100
        // $100 of DSC is how much ETH??
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //and give them a 10% bonus
        //So we are giving the liquidator $110 of weth for every 100 USD.
        //We should implement a feature to liquidate in the event the protocol is insolvent. Not gonna do that now.
        //And sweep extra amounts intSo a treasury. But we are not gonan do that either.
        //0.05 * 0.1 = 0.005. Getting 0.055 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);
        //s_DscMinted[user] = debtToCover; //s_collateralDeposited[collateral][user] -= (tokenAmountFromDebtCovered + bonusCollateral);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthfactorIsBroken(msg.sender); //also revert if the liquidators health factor got ruined in this process
    }

    ///////////////////////////////////////////
    //// Private & internal view functions ////
    ///////////////////////////////////////////

    //use underscore before funtion name to signify that these are private / internal funcs

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
    * returns how close to liquidation a user is to
    * If a user goes below 1, then they can get liquidated
    */
    function _healthFactor(address user) private view returns (uint256) {
        //total DSC minted
        //total collateral >> VALUE <<
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) {
            return type(uint256).max; //max value of uint256, used to signify infinity
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    //1. check health factor (do they have enough collateral)
    //2. revert if they  dont
    function _revertIfHealthfactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /*
    * @dev Low-level internal function. Do not call unless the function calling it is checking for health factors being broken
    * Here we are relying on Solidity on throwing an error when amountToBurn > s_DscMinted. s_DscMinted would go below 0, but it is a uint256, so Solidity will throw an underflow error 
    */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

        //emit BalancesAfterTransfer(i_dsc.balanceOf(dscFrom), i_dsc.balanceOf(address(this))); for testing only
        //this condition is technically unreachable, but this is kind of a backup if i_dsc is implemented wrong
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amountDscToBurn); //burn DSC from the contract address (after having been transferred there)
    }

    /*This is a refactored version of the original redeemCollateral function that 
    * 1) was public
    * 2) had the msg.sender hardcoded, so it was not possible to redeem collateral from the bad actor to a liquidator.
    */

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        //we are updating state so: emit
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        // _calculateHealthFactorAfter --- this would be a gas-inefficeint solution, so insead we just break CEI
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral); //we transfer the deposited collateral to the liquidator

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    ///////////////////////////////////////////
    //// Public & external view functions ////
    ///////////////////////////////////////////

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through each collateral token, get the amount they have depositied, and map it to
        //the price, get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd; //we dont need a return here bc it will return the value anyway ?!
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        //for this, we need AggregatorV3Interface
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        //1 ETH = $1000
        //The returned value 'price' from CL wil be 1000 * 1e8 (can be checked in chainlink doc)
        //1. The price (1e8) needs to be brought up to the same precisio as amount (1e18).
        //2. If the amount is 1000, then (1000e8 * 1e10) * 1000e18 = 1e6 * 1e36. Expected value is (1000**2)*1e18 = 1e6 * 1e18
        //3. Devide by 1e18.
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 UsdAmountInWei //get token amount based off the USD
    ) public view returns (uint256 tokenAmountFromDebtCovered) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]); //the new keyword is used only for creating a new instance for contracts. When using interfaces or existing contracts, one just casts the address to the contract interface. This is basically type casting.
        (, int256 price,,,) = priceFeed.latestRoundData();
        //usdAmountInWei is basically the debt to cover.
        //we should always do mupltiplication first
        // ($10e18 * 1e18) / ($2000e8 * 1e10) = 500 000 000 000 000 = 5e15 = 0.005 * e18
        return (UsdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION); //e.g. $2000 / ETH. $10 = 0.005 ETH = 0.005 * e18 wei
    }

    /*
    *Having both "getAccountInformation external" and "_getAccountInformation private" is a common design pattern.
    *The _getAccountInformation function encapsulates the core logic, making it easier to maintain and test the specific functionality without being exposed to external callers.
    *The getAccountInformation function provides a public interface that abstracts the implementation details and complexity of the internal logic
    */
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    /*pure function: does not modifiy or read the blockchain state.
    *Constants are part of the contract's state, but they is hardcoded into the contract's bytecode. 
    *The function getConstant is able to return MY_CONSTANT and still be marked as pure because 
    *it doesn't actually perform a state read at runtime; it simply returns a value that is known at compile time.
    */
    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }
}
