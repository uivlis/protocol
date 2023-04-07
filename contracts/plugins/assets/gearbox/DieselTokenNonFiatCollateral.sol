// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../AppreciatingFiatCollateral.sol";


interface IDieselToken is IERC20 {
    /// @dev Returns the address of the pool this Diesel token belongs to
    function poolService() external view returns (address);
}

interface IPoolService {
    /// @dev Returns the current exchange rate of Diesel tokens to underlying
    function getDieselRate_RAY() public view override returns (uint256);
    /// @dev Returns the address of the underlying
    function underlyingToken() external view returns (address);
}

/**
 * @title DieselTokenNonFiatCollateral
 * @notice Collateral plugin for dTokens of assets that require default checks
 * such as WBTC and wstETH
 * Expected: {tok} != {ref}, {ref} is pegged to {target} unless defaulting, {target} != {UoA}
 */
contract DiselTokenNonFiatCollateral is AppreciatingFiatCollateral {
    using OracleLib for AggregatorV3Interface;
    using FixLib for uint192;

    AggregatorV3Interface public immutable targetUnitChainlinkFeed; // {UoA/target}
    uint48 public immutable targetUnitOracleTimeout; // {s}

    /// @param config.chainlinkFeed Feed units: {target/ref}
    /// @param targetUnitChainlinkFeed_ Feed units: {UoA/target}
    /// @param targetUnitOracleTimeout_ {s} oracle timeout to use for targetUnitChainlinkFeed
    /// @param revenueHiding {1} A value like 1e-6 that represents the maximum refPerTok to hide
    constructor(CollateralConfig memory config, uint192 revenueHiding)
        AppreciatingFiatCollateral(config, revenueHiding)
    {
        require(address(targetUnitChainlinkFeed_) != address(0), "missing targetUnit feed");
        require(targetUnitOracleTimeout_ > 0, "targetUnitOracleTimeout zero");
        targetUnitChainlinkFeed = targetUnitChainlinkFeed_;
        targetUnitOracleTimeout = targetUnitOracleTimeout_;
    }

    /// Can revert, used by other contract functions in order to catch errors
    /// @return low {UoA/tok} The low price estimate
    /// @return high {UoA/tok} The high price estimate
    /// @return pegPrice {target/ref}
    function tryPrice()
        external
        view
        override
        returns (
            uint192 low,
            uint192 high,
            uint192 pegPrice
        )
    {
        pegPrice = chainlinkFeed.price(oracleTimeout); // {target/ref}

        // {UoA/tok} = {UoA/target} * {target/ref} * {ref/tok}
        uint192 p = targetUnitChainlinkFeed.price(targetUnitOracleTimeout).mul(pegPrice).mul(
            _underlyingRefPerTok()
        );
        uint192 err = p.mul(oracleError, CEIL);

        low = p - err;
        high = p + err;
        // assert(low <= high); obviously true just by inspection
    }

    /// @return {ref/tok} Actual quantity of whole reference units per whole collateral tokens
    function _underlyingRefPerTok() internal view override returns (uint192) {
        uint256 rateInRAYs = IPoolService(
                IDieselToken(address(erc20)).poolService()
            ).getDieselRate_RAY();
        return shiftl_toFix(rateInRAYs, -27);
    }

    /// Claim rewards earned by holding a balance of the ERC20 token
    /// @dev Use delegatecall
    function claimRewards() external virtual override(Asset, IRewardable) {
        emit RewardsClaimed(IPoolService(
                IDieselToken(address(erc20)).poolService()
            ).underlyingToken(), 0);
    }
}

