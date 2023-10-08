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

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./library/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Hammad
 *
 * This system is designed to be as minimal as possible, and have the tokens maintain a 1 token = 1$ peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of DSC system.It handles all the logic for minting and redeeming DSC, as well as depositing  & withdrawing collateral.
 * @notice This contract is very losely based on MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    ///////////////
    // Errors//
    //////////////
    error DSC__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSC__NotAllowedToken();
    error DSCEngine__TransferFail();
    error DSCEngine_BreakHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine__HealthFacctorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////
    // Types//
    //////////////

    using OracleLib for AggregatorV3Interface;

    ///////////////
    // State Variables//
    //////////////

    uint256 private constant ADDITIONAL_FEED_PERCISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // need to be overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ///////////////
    // Events//
    //////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    ///////////////
    // Modifier//
    //////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSC__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSC__NotAllowedToken();
        }
        _;
    }

    ///////////////
    // Functions//
    //////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USD price Feed
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH/USD, BTC/USD, MKR/USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////
    //External Functions//
    //////////////////

    /**
     *
     * @param tokenCollateralAddress The address of token to deposit as collateral
     * @param amountCollateral  The amount of collateralto deposit
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */

    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice folloes CEI (Checks, Effeccts and Interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFail();
        }
    }

    /**
     *
     * @param tokenCollateralAddress  the collateral address to redeem
     * @param amountCollateral the amount of collateral to redeem
     * @param amountDscToBurn the amount of Dsc to burn
     * @notice This fun burn DSC and redeem underlying collateral in one transaction
     */

    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    // In order to rdeem collateral
    // 1. healthfactor must be over 1 After collateral pulled
    // CEI
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // 100 - 1000 [revert]

        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount o decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     *
     */

    // Check if the Collateral value > DSC amount. price, feed, value
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // If they minted too much ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // If we do start nearing underCollaterallization, we need someine to liquidate positions

    // $100 ETH backing $50 DSC
    // $20 ETH back $50 DSC <- DSC isn't worth $1 !!!

    //$75 backing $50 DSC
    // liquidator token $75 backing and burns off the $50 DSC

    // If someone is almost undercollateralized, we will pay you to liquidate them!

    /**
     *
     * @param collateral the ERC20 collateral address to liquidate from the user
     * @param user the user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtTOCover the amount of DSC you want to burn to improve the users health factor
     * @notice You can partially Liquidate a user.
     * @notice you will get a liquidation bonus for taking the users funds
     * @notice This func working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     *
     * FOllows CEI --> Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtTOCover)
        external
        moreThanZero(debtTOCover)
        nonReentrant
    {
        // need to check the health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFacctorOk();
        }

        // We want to burn their DSC
        // And tak etheir collateral
        // Bad user : 140$ eth , $100 dsc
        //debtTOCover = $100
        // $100 of DSC == ??? ETH?
        uint256 tokenAmountFromDebtCoverd = getTokenAmountFromUsd(collateral, debtTOCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of Weth for 100 DSC
        // We should implement a feature to liquidate int he event the protocol is inslvent
        // And sweep extra amount into treasury

        // 0.05 * 0.1 = 0.005 Getting 0.055 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCoverd * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCoverd + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtTOCover, user, msg.sender);
        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    ////////////////////////////////
    //Private & Internal view Functions//
    ////////////////////////////////

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFail();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFail();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     *
     */

    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral Value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // $150 ETH / 100 DSC = 1.5
        // 1000 * 50 = 7500 / 100 = (75 / 100) < 1

        // $1000 ETH / 100 DSC
        // 100 *50 = 50000 / 100 = (500 / 100) >1

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        //return (collateralValueInUsd / totalDscMinted);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userhealthFactor = _healthFactor(user);
        if (userhealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_BreakHealthFactor(userhealthFactor);
        }
    }

    ////////////////////////////////////
    //Public & External View Functions//
    ////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH ??
        // $2000/ ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PERCISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token , get the amount they have deposited, and map it to
        // the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = $1000
        // 1 ETH = 1000*10^8
        return ((uint256(price)) * ADDITIONAL_FEED_PERCISION * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
