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

//install: forge install OpenZeppelin/openzeppelin-contracts --no-commit
//import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//install: forge install smartcontractkit/chainlink-brownie-contracts@0.6.1 --no-commit
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    ////////////////////////////
    ////// Errors ///////////
    ////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSC_Engine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();

    ////////////////////////////
    ////// State vars //////////
    ////////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_TRESHOLD = 50; //means one need to be 200 % overcollaterized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    //mapping(address => bool) private s_tokentoAllowed;    //we could do this, but we already know we are gonna need price feeds. So better:
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; //mapping to a mapping
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc; //immutable

    ////////////////////////////
    ////// Events ///////////
    ////////////////////////////

    event CollateralDepositied(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

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
            revert DSC_Engine__NotAllowedToken();
            _;
        }
    }

    ////////////////////////////
    ////// Functions ///////////
    ////////////////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress //DSCEngine needs to know about our DSC address
    ) {
        //arrays and plural, as different chains will have different addresses
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
    function depositiCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 dscToMint)
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
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDepositied(msg.sender, tokenCollateralAddress, amountCollateral); //we are modifying state so we should have an event emitted
        //interactions
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral); //this returns a bool

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
        //if they try to redeem more than they have, we rely on solidity to revert:
        //newer versions of solidity dont allow unsafe math
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        //we are updating state so: emit
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);
        // _calculateHealthFactorAfter --- this would be a gas-inefficeint solution, so insead we just break CEI
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral); //we transfer the deposited collateral back to the sender

        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        _revertIfHealthfactorIsBroken(msg.sender);
    }

    //1. Check if the collateral value is > DSC amount.This involves: price feeds, checking values...
    //ppl can decide how much they want to mint
    //probably we dont need the nonReentrant modifier
    /*
    * @notice follows CEI
    * @param amountDscToMint The amount of decentralized stablecoins to mint
    * @notice they must have more collateral value than the minimum treshold
    *
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
        s_DscMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);

        //this condition is technically unreachable, but this is kind of a backup if i_dsc is implemented wrong
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(amount);
        _revertIfHealthfactorIsBroken(msg.sender); //backup, probably this will never hit
    }

    //users can call this to kick ppl out of the system who are too close to become undercollaterized
    function liquidate() external {}

    //how healty ppl are
    function getHealthFactor() external view {}

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
        uint256 collateralAdjustedForTreshold = (collateralValueInUsd * LIQUIDATION_TRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForTreshold * PRECISION) / totalDscMinted;
    }

    //1. check health factor (do they have enough collateral)
    //2. revert if they  dont
    function _revertIfHealthfactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
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
        //return price * amount; ----but this would be way too big. E.g. if the amount is 1000, then (1000 * 1e8) * 1000 * 1e18. We need same units of precision. So instead, do (1000 * 1e8 * (1e10)) * 1000 * 1e18 / 1e18
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
