// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IAsset.sol";
import "../interfaces/IAssetRegistry.sol";
import "../interfaces/IFacadeRead.sol";
import "../interfaces/IRToken.sol";
import "../interfaces/IStRSR.sol";
import "../libraries/Fixed.sol";
import "../p1/BasketHandler.sol";
import "../p1/BackingManager.sol";
import "../p1/Furnace.sol";
import "../p1/RToken.sol";
import "../p1/RevenueTrader.sol";
import "../p1/StRSRVotes.sol";

/**
 * @title Facade
 * @notice A UX-friendly layer for reading out the state of an RToken in summary views.
 * @custom:static-call - Use ethers callStatic() to get result after update; do not execute
 */
contract FacadeRead is IFacadeRead {
    using FixLib for uint192;

    // === Static Calls ===

    /// @return {qRTok} How many RToken `account` can issue given current holdings
    /// @custom:static-call
    function maxIssuable(IRToken rToken, address account) external returns (uint256) {
        IMain main = rToken.main();
        main.poke();
        // {BU}

        BasketRange memory basketsHeld = main.basketHandler().basketsHeldBy(account);
        uint192 needed = rToken.basketsNeeded();

        int8 decimals = int8(rToken.decimals());

        // return {qRTok} = {BU} * {(1 RToken) qRTok/BU)}
        if (needed.eq(FIX_ZERO)) return basketsHeld.bottom.shiftl_toUint(decimals);

        uint192 totalSupply = shiftl_toFix(rToken.totalSupply(), -decimals); // {rTok}

        // {qRTok} = {BU} * {rTok} / {BU} * {qRTok/rTok}
        return basketsHeld.bottom.mulDiv(totalSupply, needed).shiftl_toUint(decimals);
    }

    /// @return tokens The erc20 needed for the issuance
    /// @return deposits {qTok} The deposits necessary to issue `amount` RToken
    /// @return depositsUoA {UoA} The UoA value of the deposits necessary to issue `amount` RToken
    /// @custom:static-call
    function issue(IRToken rToken, uint256 amount)
        external
        returns (
            address[] memory tokens,
            uint256[] memory deposits,
            uint192[] memory depositsUoA
        )
    {
        IMain main = rToken.main();
        main.poke();
        IRToken rTok = rToken;
        IBasketHandler bh = main.basketHandler();
        IAssetRegistry reg = main.assetRegistry();

        // Compute # of baskets to create `amount` qRTok
        uint192 baskets = (rTok.totalSupply() > 0) // {BU}
            ? rTok.basketsNeeded().muluDivu(amount, rTok.totalSupply()) // {BU * qRTok / qRTok}
            : _safeWrap(amount); // take advantage of RToken having 18 decimals

        (tokens, deposits) = bh.quote(baskets, CEIL);
        depositsUoA = new uint192[](tokens.length);

        for (uint256 i = 0; i < tokens.length; ++i) {
            IAsset asset = reg.toAsset(IERC20(tokens[i]));
            (uint192 low, uint192 high) = asset.price();
            if (low == 0) continue;

            uint192 mid = (low + high) / 2;

            // {UoA} = {tok} * {UoA/Tok}
            depositsUoA[i] = shiftl_toFix(deposits[i], -int8(asset.erc20Decimals())).mul(mid);
        }
    }

    /// @return tokens The erc20s returned for the redemption
    /// @return withdrawals The balances necessary to issue `amount` RToken
    /// @return isProrata True if the redemption is prorata and not full
    /// @custom:static-call
    function redeem(
        IRToken rToken,
        uint256 amount,
        uint48 basketNonce
    )
        external
        returns (
            address[] memory tokens,
            uint256[] memory withdrawals,
            bool isProrata
        )
    {
        IMain main = rToken.main();
        main.poke();
        IRToken rTok = rToken;
        IBasketHandler bh = main.basketHandler();
        uint256 supply = rTok.totalSupply();
        require(bh.nonce() == basketNonce, "non-current basket nonce");

        // D18{BU} = D18{BU} * {qRTok} / {qRTok}
        uint192 basketsRedeemed = rTok.basketsNeeded().muluDivu(amount, supply);

        (tokens, withdrawals) = bh.quote(basketsRedeemed, FLOOR);

        // Bound each withdrawal by the prorata share, in case we're currently under-collateralized
        address backingManager = address(main.backingManager());
        for (uint256 i = 0; i < tokens.length; ++i) {
            // {qTok} = {qTok} * {qRTok} / {qRTok}
            uint256 prorata = mulDiv256(
                IERC20Upgradeable(tokens[i]).balanceOf(backingManager),
                amount,
                supply
            ); // FLOOR

            if (prorata < withdrawals[i]) {
                withdrawals[i] = prorata;
                isProrata = true;
            }
        }
    }

    /// @return erc20s The ERC20 addresses in the current basket
    /// @return uoaShares {1} The proportion of the basket associated with each ERC20
    /// @return targets The bytes32 representations of the target unit associated with each ERC20
    /// @custom:static-call
    function basketBreakdown(RTokenP1 rToken)
        external
        returns (
            address[] memory erc20s,
            uint192[] memory uoaShares,
            bytes32[] memory targets
        )
    {
        uint256[] memory deposits;
        IAssetRegistry assetRegistry = rToken.main().assetRegistry();
        IBasketHandler basketHandler = rToken.main().basketHandler();

        // (erc20s, deposits) = issue(rToken, FIX_ONE);

        // solhint-disable-next-line no-empty-blocks
        try rToken.main().furnace().melt() {} catch {}

        (erc20s, deposits) = basketHandler.quote(FIX_ONE, CEIL);

        // Calculate uoaAmts
        uint192 uoaSum;
        uint192[] memory uoaAmts = new uint192[](erc20s.length);
        targets = new bytes32[](erc20s.length);
        for (uint256 i = 0; i < erc20s.length; ++i) {
            ICollateral coll = assetRegistry.toColl(IERC20(erc20s[i]));
            int8 decimals = int8(IERC20Metadata(erc20s[i]).decimals());
            (uint192 lowPrice, uint192 highPrice) = coll.price();
            uint192 midPrice = lowPrice > 0 ? lowPrice.plus(highPrice).div(2) : lowPrice;

            // {UoA} = {qTok} * {tok/qTok} * {UoA/tok}
            uoaAmts[i] = shiftl_toFix(deposits[i], -decimals).mul(midPrice);
            uoaSum += uoaAmts[i];
            targets[i] = coll.targetName();
        }

        uoaShares = new uint192[](erc20s.length);
        for (uint256 i = 0; i < erc20s.length; ++i) {
            uoaShares[i] = uoaAmts[i].div(uoaSum);
        }
    }

    // === Views ===

    /// @param account The account for the query
    /// @return unstakings All the pending StRSR unstakings for an account
    /// @custom:view
    function pendingUnstakings(RTokenP1 rToken, address account)
        external
        view
        returns (Pending[] memory unstakings)
    {
        StRSRP1Votes stRSR = StRSRP1Votes(address(rToken.main().stRSR()));
        uint256 era = stRSR.currentEra();
        uint256 left = stRSR.firstRemainingDraft(era, account);
        uint256 right = stRSR.draftQueueLen(era, account);

        unstakings = new Pending[](right - left);
        for (uint256 i = 0; i < right - left; i++) {
            (uint192 drafts, uint64 availableAt) = stRSR.draftQueues(era, account, i + left);

            uint192 diff = drafts;
            if (i + left > 0) {
                (uint192 prevDrafts, ) = stRSR.draftQueues(era, account, i + left - 1);
                diff = drafts - prevDrafts;
            }

            unstakings[i] = Pending(i + left, availableAt, diff);
        }
    }

    /// Returns the prime basket
    /// @dev Indices are shared aross return values
    /// @return erc20s The erc20s in the prime basket
    /// @return targetNames The bytes32 name identifier of the target unit, per ERC20
    /// @return targetAmts {target/BU} The amount of the target unit in the basket, per ERC20
    function primeBasket(RTokenP1 rToken)
        external
        view
        returns (
            IERC20[] memory erc20s,
            bytes32[] memory targetNames,
            uint192[] memory targetAmts
        )
    {
        return BasketHandlerP1(address(rToken.main().basketHandler())).getPrimeBasket();
    }

    /// @return tokens The ERC20s backing the RToken
    function basketTokens(IRToken rToken) external view returns (address[] memory tokens) {
        (tokens, ) = rToken.main().basketHandler().quote(FIX_ONE, RoundingMode.FLOOR);
    }

    /// Returns the backup configuration for a given targetName
    /// @param targetName The name of the target unit to lookup the backup for
    /// @return erc20s The backup erc20s for the target unit, in order of most to least desirable
    /// @return max The maximum number of tokens from the array to use at a single time
    function backupConfig(RTokenP1 rToken, bytes32 targetName)
        external
        view
        returns (IERC20[] memory erc20s, uint256 max)
    {
        return BasketHandlerP1(address(rToken.main().basketHandler())).getBackupConfig(targetName);
    }

    /// @return stTokenAddress The address of the corresponding stToken for the rToken
    function stToken(IRToken rToken) external view returns (IStRSR stTokenAddress) {
        IMain main = rToken.main();
        stTokenAddress = main.stRSR();
    }

    /// @return backing {1} The worstcase collateralization % the protocol will have after trading
    /// @return overCollateralization {1} The over-collateralization value relative to the
    ///     fully-backed value as a %
    function backingOverview(IRToken rToken)
        external
        view
        returns (uint192 backing, uint192 overCollateralization)
    {
        uint256 supply = rToken.totalSupply();
        if (supply == 0) return (0, 0);

        // {UoA/BU}
        (uint192 buPriceLow, uint192 buPriceHigh) = rToken.main().basketHandler().price();
        // untestable:
        //      if buPriceLow==0 then basketMidPrice=0 and uoaNeeded=0
        //      this functions will then panic when `uoaHeld.div(uoaNeeded)`
        uint192 basketMidPrice = buPriceLow > 0 ? buPriceLow.plus(buPriceHigh).div(2) : buPriceLow;

        // {UoA} = {BU} * {UoA/BU}
        uint192 uoaNeeded = rToken.basketsNeeded().mul(basketMidPrice);

        // Useful abbreviations
        IAssetRegistry assetRegistry = rToken.main().assetRegistry();
        address backingMgr = address(rToken.main().backingManager());
        IERC20 rsr = rToken.main().rsr();

        // Compute backing
        {
            IERC20[] memory erc20s = assetRegistry.erc20s();

            // Bound each withdrawal by the prorata share, in case under-collateralized
            uint192 uoaHeld;
            for (uint256 i = 0; i < erc20s.length; i++) {
                if (erc20s[i] == rsr) continue;

                IAsset asset = assetRegistry.toAsset(IERC20(erc20s[i]));
                (uint192 lowPrice, uint192 highPrice) = asset.price();
                uint192 midPrice = lowPrice > 0 ? lowPrice.plus(highPrice).div(2) : lowPrice;

                // {UoA} = {tok} * {UoA/tok}
                uint192 uoa = asset.bal(backingMgr).mul(midPrice);
                uoaHeld = uoaHeld.plus(uoa);
            }

            // {1} = {UoA} / {UoA}
            backing = uoaHeld.div(uoaNeeded);
        }

        // Compute overCollateralization
        {
            IAsset rsrAsset = assetRegistry.toAsset(rsr);

            // {tok} = {tok} + {tok}
            uint192 rsrBal = rsrAsset.bal(backingMgr).plus(
                rsrAsset.bal(address(rToken.main().stRSR()))
            );

            (uint192 lowPrice, uint192 highPrice) = rsrAsset.price();
            uint192 midPrice = lowPrice > 0 ? lowPrice.plus(highPrice).div(2) : lowPrice;

            // {UoA} = {tok} * {UoA/tok}
            uint192 rsrUoA = rsrBal.mul(midPrice);

            // {1} = {UoA} / {UoA}
            overCollateralization = rsrUoA.div(uoaNeeded);
        }
    }

    /// @return erc20s The registered ERC20s
    /// @return balances {qTok} The held balances of each ERC20 at the trader
    /// @return balancesNeeded {qTok} The needed balance of each ERC20 at the trader
    function traderBalances(IRToken rToken, ITrading trader)
        external
        view
        returns (
            IERC20[] memory erc20s,
            uint256[] memory balances,
            uint256[] memory balancesNeeded
        )
    {
        IBackingManager backingManager = rToken.main().backingManager();
        IBasketHandler basketHandler = rToken.main().basketHandler();

        erc20s = rToken.main().assetRegistry().erc20s();
        balances = new uint256[](erc20s.length);
        balancesNeeded = new uint256[](erc20s.length);

        bool isBackingManager = trader == backingManager;
        uint192 basketsNeeded = rToken.basketsNeeded(); // {BU}

        for (uint256 i = 0; i < erc20s.length; ++i) {
            balances[i] = erc20s[i].balanceOf(address(trader));

            if (isBackingManager) {
                // {qTok} = {tok/BU} * {BU} * {tok} * {qTok/tok}
                balancesNeeded[i] = safeMul(
                    basketHandler.quantity(erc20s[i]),
                    basketsNeeded,
                    RoundingMode.FLOOR // FLOOR to match redemption
                ).shiftl_toUint(
                        int8(IERC20Metadata(address(erc20s[i])).decimals()),
                        RoundingMode.FLOOR
                    );
            }
        }
    }

    /// @return low {UoA/tok} The low price of the RToken as given by the relevant RTokenAsset
    /// @return high {UoA/tok} The high price of the RToken as given by the relevant RTokenAsset
    function price(IRToken rToken) external view returns (uint192 low, uint192 high) {
        return rToken.main().assetRegistry().toAsset(IERC20(address(rToken))).price();
    }

    /// @return erc20s The list of ERC20s that have auctions that can be settled, for given trader
    function auctionsSettleable(ITrading trader) external view returns (IERC20[] memory erc20s) {
        IERC20[] memory allERC20s = trader.main().assetRegistry().erc20s();

        // Calculate which erc20s can have auctions settled
        uint256 num;
        IERC20[] memory unfiltered = new IERC20[](allERC20s.length); // will filter down later
        for (uint256 i = 0; i < allERC20s.length; ++i) {
            ITrade trade = trader.trades(allERC20s[i]);
            if (address(trade) != address(0) && trade.canSettle()) {
                unfiltered[num] = allERC20s[i];
                ++num;
            }
        }

        // Filter down
        erc20s = new IERC20[](num);
        for (uint256 i = 0; i < num; ++i) {
            erc20s[i] = unfiltered[i];
        }
    }

    // === Private ===

    /// Multiply two fixes, rounding up to FIX_MAX and down to 0
    /// @param a First param to multiply
    /// @param b Second param to multiply
    function safeMul(
        uint192 a,
        uint192 b,
        RoundingMode rounding
    ) internal pure returns (uint192) {
        // untestable:
        //      a will never = 0 here because of the check in _price()
        if (a == 0 || b == 0) return 0;
        // untestable:
        //      a = FIX_MAX iff b = 0
        if (a == FIX_MAX || b == FIX_MAX) return FIX_MAX;

        // return FIX_MAX instead of throwing overflow errors.
        unchecked {
            // p and mul *are* Fix values, so have 18 decimals (D18)
            uint256 rawDelta = uint256(b) * a; // {D36} = {D18} * {D18}
            // if we overflowed, then return FIX_MAX
            if (rawDelta / b != a) return FIX_MAX;
            uint256 shiftDelta = rawDelta;

            // add in rounding
            if (rounding == RoundingMode.ROUND) shiftDelta += (FIX_ONE / 2);
            else if (rounding == RoundingMode.CEIL) shiftDelta += FIX_ONE - 1;

            // untestable (here there be dragons):
            // (below explanation is for the ROUND case, but it extends to the FLOOR/CEIL too)
            //          A)  shiftDelta = rawDelta + (FIX_ONE / 2)
            //      shiftDelta overflows if:
            //          B)  shiftDelta = MAX_UINT256 - FIX_ONE/2 + 1
            //              rawDelta + (FIX_ONE/2) = MAX_UINT256 - FIX_ONE/2 + 1
            //              b * a = MAX_UINT256 - FIX_ONE + 1
            //      therefore shiftDelta overflows if:
            //          C)  b = (MAX_UINT256 - FIX_ONE + 1) / a
            //      MAX_UINT256 ~= 1e77 , FIX_MAX ~= 6e57 (6e20 difference in magnitude)
            //      a <= 1e21 (MAX_TARGET_AMT)
            //      a must be between 1e19 & 1e20 in order for b in (C) to be uint192,
            //      but a would have to be < 1e18 in order for (A) to overflow
            if (shiftDelta < rawDelta) return FIX_MAX;

            // return FIX_MAX if return result would truncate
            if (shiftDelta / FIX_ONE > FIX_MAX) return FIX_MAX;

            // return _div(rawDelta, FIX_ONE, rounding)
            return uint192(shiftDelta / FIX_ONE); // {D18} = {D36} / {D18}
        }
    }
}
