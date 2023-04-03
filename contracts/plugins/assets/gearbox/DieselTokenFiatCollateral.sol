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
 * @title DieselTokenCollateral
 * @notice Collateral plugin for dTokens of UoA-peggeed assets, like dUSDC or dDAI
 * Expected: {tok} != {ref}, {ref} is pegged to {target} unless defaulting, {target} == {UoA}
 */
contract DiselTokenFiatCollateral is AppreciatingFiatCollateral {
    using OracleLib for AggregatorV3Interface;
    using FixLib for uint192;

    // solhint-disable no-empty-blocks

    /// @param config.chainlinkFeed Feed units: {UoA/ref}
    /// @param revenueHiding {1} A value like 1e-6 that represents the maximum refPerTok to hide
    constructor(CollateralConfig memory config, uint192 revenueHiding)
        AppreciatingFiatCollateral(config, revenueHiding)
    {}

    // solhint-enable no-empty-blocks

    /// @return {ref/tok} Actual quantity of whole reference units per whole collateral tokens
    function _underlyingRefPerTok() internal view override returns (uint192) {
        uint256 rateInRAYs = IPoolService(
                IDieselToken(address(erc20)).poolService()
            ).getDieselRate_RAY();
        return rateInRAYs.shiftl_toFix(-27);
    }

    /// Claim rewards earned by holding a balance of the ERC20 token
    /// @dev Use delegatecall
    function claimRewards() external virtual override(Asset, IRewardable) {
        emit RewardsClaimed(IPoolService(
                IDieselToken(address(erc20)).poolService()
            ).underlyingToken(), 0);
    }
}

