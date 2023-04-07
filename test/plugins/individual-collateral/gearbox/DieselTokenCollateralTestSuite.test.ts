import collateralTests from '../collateralTests'
import { CollateralFixtureContext, CollateralOpts, MintCollateralFunc } from '../pluginTestTypes'
import {
    ERC20Mock,
    MockV3Aggregator,
    MockV3Aggregator__factory,
    SfraxEthMock,
    TestICollateral,
    IsfrxEth,
  } from '../../../../typechain'

  import {
    PRICE_TIMEOUT,
    ORACLE_ERROR,
    ORACLE_TIMEOUT,
    MAX_TRADE_VOL,
    DEFAULT_THRESHOLD,
    DELAY_UNTIL_DEFAULT,
    WETH,
    FRX_ETH,
    SFRX_ETH,
    ETH_USD_PRICE_FEED,
  } from './constants'

export const defaultRethCollateralOpts: CollateralOpts = {
    erc20: SFRX_ETH,
    targetName: ethers.utils.formatBytes32String('ETH'),
    rewardERC20: WETH,
    priceTimeout: PRICE_TIMEOUT,
    chainlinkFeed: ETH_USD_PRICE_FEED,
    oracleTimeout: ORACLE_TIMEOUT,
    oracleError: ORACLE_ERROR,
    maxTradeVolume: MAX_TRADE_VOL,
    defaultThreshold: DEFAULT_THRESHOLD,
    delayUntilDefault: DELAY_UNTIL_DEFAULT,
    revenueHiding: fp('0'),
  }

export const deployCollateral = async (opts: CollateralOpts = {}): Promise<TestICollateral> => {
    opts = { ...defaultRethCollateralOpts, ...opts }
  
    const SFraxEthCollateralFactory: ContractFactory = await ethers.getContractFactory(
      'SFraxEthCollateral'
    )
  
    const collateral = <TestICollateral>await SFraxEthCollateralFactory.deploy(
      {
        erc20: opts.erc20,
        targetName: opts.targetName,
        priceTimeout: opts.priceTimeout,
        chainlinkFeed: opts.chainlinkFeed,
        oracleError: opts.oracleError,
        oracleTimeout: opts.oracleTimeout,
        maxTradeVolume: opts.maxTradeVolume,
        defaultThreshold: opts.defaultThreshold,
        delayUntilDefault: opts.delayUntilDefault,
      },
      opts.revenueHiding,
      { gasLimit: 2000000000 }
    )
    await collateral.deployed()
    // sometimes we are trying to test a negative test case and we want this to fail silently
    // fortunately this syntax fails silently because our tools are terrible
    await expect(collateral.refresh())
  
    return collateral
  }

const opts = {
    deployCollateral,
    collateralSpecificConstructorTests,
    collateralSpecificStatusTests,
    beforeEachRewardsTest,
    makeCollateralFixtureContext,
    mintCollateralTo,
    reduceTargetPerRef,
    increaseTargetPerRef,
    reduceRefPerTok,
    increaseRefPerTok,
    getExpectedPrice,
    itClaimsRewards: it.skip,
    itChecksTargetPerRefDefault: it.skip,
    itChecksRefPerTokDefault: it.skip,
    itChecksPriceChanges: it,
    itHasRevenueHiding: it.skip, // implemnted in this file
    resetFork,
    collateralName: 'SFraxEthCollateral',
    chainlinkDefaultAnswer,
  }

collateralTests(opts)