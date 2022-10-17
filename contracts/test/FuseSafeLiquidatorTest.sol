// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "ds-test/test.sol";
import "forge-std/Vm.sol";

import { CToken } from "../compound/CToken.sol";
import { Comptroller } from "../compound/Comptroller.sol";
import { CErc20Delegate } from "../compound/CErc20Delegate.sol";
import { MasterPriceOracle } from "../oracles/MasterPriceOracle.sol";

import { WETH } from "solmate/tokens/WETH.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";

import "../FuseSafeLiquidator.sol";
import "../FusePoolDirectory.sol";
import "./config/BaseTest.t.sol";
import "../liquidators/JarvisLiquidatorFunder.sol";
import "../liquidators/CurveLpTokenLiquidator.sol";
import "../liquidators/UniswapLpTokenLiquidator.sol";
import "../liquidators/CurveLpTokenLiquidatorNoRegistry.sol";
import "../liquidators/UniswapV2Liquidator.sol";
import "../liquidators/CurveSwapLiquidator.sol";

contract MockRedemptionStrategy is IRedemptionStrategy {
  function redeem(
    IERC20Upgradeable inputToken,
    uint256 inputAmount,
    bytes memory strategyData
  ) external returns (IERC20Upgradeable outputToken, uint256 outputAmount) {
    return (IERC20Upgradeable(address(0)), 1);
  }
}

contract FuseSafeLiquidatorTest is BaseTest {
  FuseSafeLiquidator fsl;
  address alice = address(10);
  address uniswapRouter;

  function setUp() public {
    if (block.chainid == BSC_MAINNET) {
      uniswapRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
      fsl = FuseSafeLiquidator(payable(0xc9C3D317E89f4390A564D56180bBB1842CF3c99C));
    } else if (block.chainid == POLYGON_MAINNET) {
      uniswapRouter = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;
      fsl = FuseSafeLiquidator(payable(0x37b3890B9b3a5e158EAFDA243d4640c5349aFC15));
    } else {
      uniswapRouter = ap.getAddress("IUniswapV2Router02");
      fsl = new FuseSafeLiquidator();
      fsl.initialize(address(1), address(2), address(3), address(4), "", 30);
    }
  }

  function testWhitelistRevert() public {
    IERC20Upgradeable underlyingCollateral = IERC20Upgradeable(address(0));
    uint256 underlyingCollateralSeized = 1;
    IRedemptionStrategy strategy = new MockRedemptionStrategy();
    bytes memory strategyData = "";

    vm.expectRevert("only whitelisted redemption strategies can be used");
    fsl.redeemCustomCollateral(underlyingCollateral, underlyingCollateralSeized, strategy, strategyData);
  }

  function testWhitelist() public {
    IERC20Upgradeable underlyingCollateral = IERC20Upgradeable(address(0));
    uint256 underlyingCollateralSeized = 1;
    IRedemptionStrategy strategy = new MockRedemptionStrategy();
    bytes memory strategyData = "";

    vm.prank(fsl.owner());
    fsl._whitelistRedemptionStrategy(strategy, true);
    fsl.redeemCustomCollateral(underlyingCollateral, underlyingCollateralSeized, strategy, strategyData);
  }

  function testUpgrade() public {
    //    emit log_address(fsl.owner());

    // in case these slots start to get used, please redeploy the FSL
    // with a larger storage gap to protect the owner variable of OwnableUpgradeable
    // from being overwritten by the FuseSafeLiquidator storage
    for (uint256 i = 40; i < 51; i++) {
      //      emit log_uint(i);
      address atSloti = address(uint160(uint256(vm.load(address(fsl), bytes32(i)))));
      //      emit log_address(atSloti);
      assertEq(
        atSloti,
        address(0),
        "replace the FSL proxy/storage contract with a new one before the owner variable is overwritten"
      );
    }
  }

  struct LiquidationData {
    FusePoolDirectory.FusePool[] pools;
    address[] cTokens;
    IRedemptionStrategy[] strategies;
    bytes[] redemptionDatas;
    CTokenInterface[] markets;
    address[] borrowers;
    FuseSafeLiquidator liquidator;
    IFundsConversionStrategy[] fundingStrategies;
    bytes[] fundingDatas;
    CErc20Delegate debtMarket;
    CErc20Delegate collateralMarket;
    Comptroller comptroller;
    address borrower;
    uint256 borrowAmount;
    address flashSwapFundingToken;
    IUniswapV2Pair flashSwapPair;
  }

  function getPoolAndBorrower(uint256 random, LiquidationData memory vars)
    internal
    view
    returns (Comptroller, address)
  {
    if (vars.pools.length == 0) revert("no pools to pick from");

    uint256 i = random % vars.pools.length; // random pool
    Comptroller comptroller = Comptroller(vars.pools[i].comptroller);
    address[] memory borrowers = comptroller.getAllBorrowers();

    if (borrowers.length == 0) {
      return (Comptroller(address(0)), address(0));
    } else {
      uint256 k = random % borrowers.length; // random borrower
      address borrower = borrowers[k];

      return (comptroller, borrower);
    }
  }

  function setUpDebtAndCollateralMarkets(uint256 random, LiquidationData memory vars)
    internal
    returns (
      CErc20Delegate debt,
      CErc20Delegate collateral,
      uint256 borrowAmount
    )
  {
    // debt
    for (uint256 m = 0; m < vars.markets.length; m++) {
      uint256 marketIndexWithOffset = (random + m) % vars.markets.length;
      borrowAmount = vars.markets[marketIndexWithOffset].borrowBalanceStored(vars.borrower);
      if (borrowAmount > 0) {
        debt = CErc20Delegate(address(vars.markets[marketIndexWithOffset]));
        break;
      }
    }

    if (address(debt) != address(0)) {
      emit log("debt market is");
      emit log_address(address(debt));

      uint256 shortfall = 0;
      // reduce the collateral for each market of the borrower
      // until there is shortfall for which to be liquidated
      for (uint256 m = 0; m < vars.markets.length; m++) {
        uint256 marketIndexWithOffset = (random - m) % vars.markets.length;
        if (vars.markets[marketIndexWithOffset].balanceOf(vars.borrower) > 0) {
          if (address(vars.markets[marketIndexWithOffset]) == address(debt)) continue;

          collateral = CErc20Delegate(address(vars.markets[marketIndexWithOffset]));

          // the collateral prices change
          MasterPriceOracle mpo = MasterPriceOracle(address(vars.comptroller.oracle()));
          uint256 priceCollateral = mpo.getUnderlyingPrice(ICToken(address(collateral)));
          vm.mockCall(
            address(mpo),
            abi.encodeWithSelector(mpo.getUnderlyingPrice.selector, ICToken(address(collateral))),
            abi.encode(priceCollateral / 5)
          );

          (, , shortfall) = vars.comptroller.getHypotheticalAccountLiquidity(vars.borrower, address(0), 0, 0);
          if (shortfall == 0) {
            emit log("collateral still enough");
            continue;
          } else {
            emit log("has shortfall");
            break;
          }
        }
      }
      if (shortfall == 0) {
        return (CErc20Delegate(address(0)), CErc20Delegate(address(0)), 0);
      }
    }
  }

  function testAnyLiquidation(uint256 random) public shouldRun(forChains(BSC_MAINNET)) {
    vm.assume(random > 100 && random < type(uint64).max);

    //    random = 122460273;

    LiquidationData memory vars;

    // setting up a new liquidator
    //    vars.liquidator = FuseSafeLiquidator(payable(0xc9C3D317E89f4390A564D56180bBB1842CF3c99C));
    vars.liquidator = new FuseSafeLiquidator();
    vars.liquidator.initialize(
      ap.getAddress("wtoken"),
      uniswapRouter,
      ap.getAddress("bUSD"),
      0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c, // BTCB
      "0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5",
      25
    );
    vars.pools = FusePoolDirectory(0x295d7347606F4bd810C8296bb8d75D657001fcf7).getAllPools();

    while (true) {
      // get a random pool and a random borrower from it
      (vars.comptroller, vars.borrower) = getPoolAndBorrower(random, vars);

      if (address(vars.comptroller) != address(0) && vars.borrower != address(0)) {
        // find a market in which the borrower has debt and reduce his collateral price
        vars.markets = vars.comptroller.getAllMarkets();
        (vars.debtMarket, vars.collateralMarket, vars.borrowAmount) = setUpDebtAndCollateralMarkets(random, vars);

        if (address(vars.debtMarket) != address(0) && address(vars.collateralMarket) != address(0)) {
          emit log("found testable markets at random number");
          emit log_uint(random);
          break;
        }
      }
      random++;
    }

    emit log("debt and collateral markets");
    emit log_address(address(vars.debtMarket));
    emit log_address(address(vars.collateralMarket));

    // prepare the liquidation
    address exchangeTo;

    // prepare the funding strategies
    if (vars.debtMarket.underlying() == 0x316622977073BBC3dF32E7d2A9B3c77596a0a603) {
      // jbrl
      addJbrlFundingStrategy(vars);
    } else {
      vars.fundingStrategies = new IFundsConversionStrategy[](0);
      vars.fundingDatas = new bytes[](0);
      vars.flashSwapFundingToken = vars.debtMarket.underlying();
    }

    if (vars.flashSwapFundingToken != ap.getAddress("wtoken")) {
      IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);
      address pairAddress = IUniswapV2Factory(router.factory()).getPair(
        vars.flashSwapFundingToken,
        ap.getAddress("wtoken")
      );
      vars.flashSwapPair = IUniswapV2Pair(pairAddress);
    } else {
      vars.flashSwapPair = FIRST_PAIR;
    }

    exchangeTo = vars.flashSwapFundingToken;

    // prepare the redemption strategies
    if (vars.collateralMarket.underlying() == 0x1B6E11c5DB9B15DE87714eA9934a6c52371CfEA9) {
      // 2brl
      add2BrlRedemptionStrategies(vars);
    } else if (
      vars.collateralMarket.underlying() == 0xd99c7F6C65857AC913a8f880A4cb84032AB2FC5b ||
      vars.collateralMarket.underlying() == 0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16
    ) {
      // Uniswap LP
      addUniswapLPRedemptionStrategies(vars, IUniswapV2Pair(vars.collateralMarket.underlying()));
    } else {
      vars.strategies = new IRedemptionStrategy[](0);
      vars.redemptionDatas = new bytes[](0);
    }

    // liquidate
    vm.prank(ap.owner());
    vars.liquidator.safeLiquidateToTokensWithFlashLoan(
      FuseSafeLiquidator.LiquidateToTokensWithFlashSwapVars(
        vars.borrower,
        vars.borrowAmount / 100, //repayAmount,
        ICErc20(address(vars.debtMarket)),
        ICErc20(address(vars.collateralMarket)),
        vars.flashSwapPair,
        0,
        exchangeTo,
        IUniswapV2Router02(uniswapRouter),
        IUniswapV2Router02(uniswapRouter),
        vars.strategies,
        vars.redemptionDatas,
        0,
        vars.fundingStrategies,
        vars.fundingDatas
      )
    );
  }

  function addJbrlFundingStrategy(LiquidationData memory vars) internal {
    vars.flashSwapFundingToken = ap.getAddress("bUSD");
    vars.fundingStrategies = new IFundsConversionStrategy[](1);
    vars.fundingDatas = new bytes[](1);
    vars.fundingDatas[0] = abi.encode(vars.flashSwapFundingToken, 0x0fD8170Dc284CD558325029f6AEc1538c7d99f49, 60 * 40);
    vars.fundingStrategies[0] = new JarvisLiquidatorFunder();

    // all strategies need to be whitelisted
    vm.prank(vars.liquidator.owner());
    vars.liquidator._whitelistRedemptionStrategy(vars.fundingStrategies[0], true);
  }

  function add2BrlRedemptionStrategies(LiquidationData memory vars) internal {
    vars.strategies = new IRedemptionStrategy[](2);
    vars.strategies[0] = new CurveLpTokenLiquidatorNoRegistry();
    vars.strategies[1] = new JarvisLiquidatorFunder();
    vars.redemptionDatas = new bytes[](2);
    vars.redemptionDatas[0] = abi.encode(
      uint8(0),
      0x316622977073BBC3dF32E7d2A9B3c77596a0a603,
      ap.getAddress("wtoken"),
      0x4544d21EB5B368b3f8F98DcBd03f28aC0Cf6A0CA
    );
    vars.redemptionDatas[1] = abi.encode(
      address(0x316622977073BBC3dF32E7d2A9B3c77596a0a603),
      0x0fD8170Dc284CD558325029f6AEc1538c7d99f49,
      60 * 40
    );

    // all strategies need to be whitelisted
    vm.prank(vars.liquidator.owner());
    vars.liquidator._whitelistRedemptionStrategy(vars.strategies[0], true);
    vars.liquidator._whitelistRedemptionStrategy(vars.strategies[1], true);
  }

  function addUniswapV2RedemptionStrategies(
    LiquidationData memory vars,
    address inputToken,
    address outputToken
  ) internal {
    vars.strategies = new IRedemptionStrategy[](1);
    vars.strategies[0] = new UniswapV2Liquidator();
    vars.redemptionDatas = new bytes[](1);

    address[] memory swapPath = new address[](2);
    swapPath[0] = inputToken;
    swapPath[1] = outputToken;

    bytes memory strategyData = abi.encode(uniswapRouter, swapPath);
    vars.redemptionDatas[0] = strategyData;

    vm.prank(vars.liquidator.owner());
    vars.liquidator._whitelistRedemptionStrategy(vars.strategies[0], true);
  }

  function addUniswapLPRedemptionStrategies(LiquidationData memory vars, IUniswapV2Pair pair) internal {
    vars.strategies = new IRedemptionStrategy[](1);
    vars.strategies[0] = new UniswapLpTokenLiquidator();
    vars.redemptionDatas = new bytes[](1);

    address[] memory swapToken0Path;
    address[] memory swapToken1Path;

    if (pair.token0() == ap.getAddress("wtoken")) {
      swapToken0Path = new address[](0);
      swapToken1Path = new address[](2);

      swapToken1Path[0] = pair.token1();
      swapToken1Path[1] = pair.token0();
    } else {
      swapToken0Path = new address[](2);
      swapToken1Path = new address[](0);

      swapToken0Path[0] = pair.token0();
      swapToken0Path[1] = pair.token1();
    }

    vars.redemptionDatas[0] = abi.encode(uniswapRouter, swapToken0Path, swapToken1Path);
    // all strategies need to be whitelisted
    vm.prank(vars.liquidator.owner());
    vars.liquidator._whitelistRedemptionStrategy(vars.strategies[0], true);

    if (address(vars.flashSwapPair) == address(pair)) {
      emit log("toggling the flashswap pair");
      emit log_address(address(pair));
      toggleFlashSwapPair(vars);
    }
  }

  IUniswapV2Pair FIRST_PAIR = IUniswapV2Pair(0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16); // WBNB-BUSD
  IUniswapV2Pair SECOND_PAIR = IUniswapV2Pair(0x61EB789d75A95CAa3fF50ed7E47b96c132fEc082); // WBNB-BTCB

  function toggleFlashSwapPair(LiquidationData memory vars) internal {
    if (address(vars.flashSwapPair) == address(FIRST_PAIR)) {
      vars.flashSwapPair = SECOND_PAIR;
    } else {
      vars.flashSwapPair = FIRST_PAIR;
    }
  }

  address ageurJeurPool = 0x2fFbCE9099cBed86984286A54e5932414aF4B717; // AGEUR_JEUR
  address jeurParPool = 0x0f110c55EfE62c16D553A3d3464B77e1853d0e97; // JEUR_PAR
  address jjpyJpycPool = 0xaA91CDD7abb47F821Cf07a2d38Cc8668DEAf1bdc; // JJPY_JPYC
  address jcadCadcPool = 0xA69b0D5c0C401BBA2d5162138613B5E38584F63F; // JCAD_CADC
  address jsgdXsgdPool = 0xeF75E9C7097842AcC5D0869E1dB4e5fDdf4BFDDA; // JSGD_XSGD
  address jnzdNzdsPool = 0x976A750168801F58E8AEdbCfF9328138D544cc09; // JNZD_NZDS
  address jeurEurtPool = 0x2C3cc8e698890271c8141be9F6fD6243d56B39f1; // JEUR_EUR
  address eureJeurPool = 0x2F3E9CA3bFf85B91D9fe6a9f3e8F9B1A6a4c3cF4; // EURE_JEUR

  struct CurveSwapPool {
    address pool;
    int128 preferredCoin;
  }

  CurveSwapPool[] curveSwapPools;

  // TODO remove after the next deploy configures the AP accordingly
  function configureCurveSwapPools() internal {
    curveSwapPools.push(CurveSwapPool(ageurJeurPool, 1));
    curveSwapPools.push(CurveSwapPool(jeurParPool, 1));
    curveSwapPools.push(CurveSwapPool(jjpyJpycPool, 0));
    curveSwapPools.push(CurveSwapPool(jcadCadcPool, 0));
    curveSwapPools.push(CurveSwapPool(jsgdXsgdPool, 0));
    curveSwapPools.push(CurveSwapPool(jnzdNzdsPool, 0));
    curveSwapPools.push(CurveSwapPool(jeurEurtPool, 1));
    curveSwapPools.push(CurveSwapPool(eureJeurPool, 1));

    curveSwapLiquidator = new CurveSwapLiquidator();

    for (uint8 i = 0; i < curveSwapPools.length; i++) {
      (address addr, ) = ap.redemptionStrategies(curveSwapPools[i].pool);
      if (addr == address(0)) {
        // TODO add the curve swap pools to the AP redemptionStrategies
        vm.prank(ap.owner());
        ap.setRedemptionStrategy(curveSwapPools[i].pool, address(curveSwapLiquidator), "CurveSwapLiquidator");
      }
    }
  }

  function testPolygonAnyLiquidation(uint256 random) public shouldRun(forChains(POLYGON_MAINNET)) {
    vm.assume(random > 100 && random < type(uint64).max);
    //    uint256 random = 1486;

    LiquidationData memory vars;

    // TODO extract to setup method
    {
      address usdcPolygon = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
      vm.prank(ap.owner());
      ap.setAddress("USDC", usdcPolygon);

      configureCurveSwapPools();
    }

    // setting up a new liquidator
    //    vars.liquidator = FuseSafeLiquidator(payable());
    vars.liquidator = new FuseSafeLiquidator();
    vars.liquidator.initialize(
      ap.getAddress("wtoken"),
      uniswapRouter,
      ap.getAddress("USDC"),
      ap.getAddress("wBTCToken"),
      "0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f",
      30
    );
    vars.pools = FusePoolDirectory(ap.getAddress("FusePoolDirectory")).getAllPools();

    while (true) {
      // get a random pool and a random borrower from it
      (vars.comptroller, vars.borrower) = getPoolAndBorrower(random, vars);

      if (address(vars.comptroller) != address(0) && vars.borrower != address(0)) {
        // find a market in which the borrower has debt and reduce his collateral price
        if (address(vars.comptroller) != address(0) && vars.borrower != address(0)) {
          vars.markets = vars.comptroller.getAllMarkets();
          (vars.debtMarket, vars.collateralMarket, vars.borrowAmount) = setUpDebtAndCollateralMarkets(random, vars);
        }

        if (address(vars.debtMarket) != address(0) && address(vars.collateralMarket) != address(0)) {
          //          if (vars.debtMarket.underlying() == 0xBD1fe73e1f12bD2bc237De9b626F056f21f86427) { // TODO remove when done testing MAI
          emit log("found testable markets at random number");
          emit log_uint(random);
          break;
          //          }
        }
      }
      random++;
    }

    emit log("debt and collateral markets");
    emit log_address(address(vars.debtMarket));
    emit log_address(address(vars.collateralMarket));

    // prepare the liquidation
    address exchangeTo;

    addPolygonStrategies(vars);

    emit log("flash swap funding token is");
    emit log_address(vars.flashSwapFundingToken);

    if (vars.flashSwapFundingToken != ap.getAddress("wtoken")) {
      IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);
      address pairAddress = IUniswapV2Factory(router.factory()).getPair(
        vars.flashSwapFundingToken,
        ap.getAddress("wtoken")
      );

      vars.flashSwapPair = IUniswapV2Pair(pairAddress);
    } else {
      vars.flashSwapPair = FIRST_PAIR;
    }

    exchangeTo = vars.flashSwapFundingToken;

    // add the redemption strategies
    if (exchangeTo != address(0)) {
      address tokenToRedeem = vars.collateralMarket.underlying();
      while (tokenToRedeem != exchangeTo) {
        (address addr, string memory contractInterface) = ap.redemptionStrategies(tokenToRedeem);
        if (addr == address(0)) break;
        address outputToken = addPolygonRedemptionStrategy(
          vars,
          IRedemptionStrategy(addr),
          contractInterface,
          tokenToRedeem
        );
        tokenToRedeem = outputToken;
      }
      vars.redemptionDatas = redemptionDatas;
      vars.strategies = redemptionStrategies;
    }

    //    if (vars.collateralMarket.underlying() == 0xa3Fa99A148fA48D14Ed51d610c367C61876997F1) {
    //      // MAI
    //      // Uniswap
    //      addUniswapV2RedemptionStrategies(vars, 0xa3Fa99A148fA48D14Ed51d610c367C61876997F1, ap.getAddress("USDC"));
    //    }

    // liquidate
    vm.prank(ap.owner());
    try
      vars.liquidator.safeLiquidateToTokensWithFlashLoan(
        FuseSafeLiquidator.LiquidateToTokensWithFlashSwapVars(
          vars.borrower,
          vars.borrowAmount / 100, //repayAmount,
          ICErc20(address(vars.debtMarket)),
          ICErc20(address(vars.collateralMarket)),
          vars.flashSwapPair,
          0,
          exchangeTo,
          IUniswapV2Router02(uniswapRouter),
          IUniswapV2Router02(uniswapRouter),
          vars.strategies,
          vars.redemptionDatas,
          0,
          vars.fundingStrategies,
          vars.fundingDatas
        )
      )
    {
      // noop
    } catch Error(string memory reason) {
      if (compareStrings(reason, "Number of tokens less than minimum limit")) {
        emit log("jarvis pool failing, that's ok");
      } else {
        revert(reason);
      }
    }
  }

  function addJmxnFundingStrategy(LiquidationData memory vars) internal {
    vars.flashSwapFundingToken = ap.getAddress("USDC");
    vars.fundingStrategies = new IFundsConversionStrategy[](1);
    vars.fundingDatas = new bytes[](1);
    vars.fundingDatas[0] = abi.encode(vars.flashSwapFundingToken, 0x25E9F976f5020F6BF2d417b231e5f414b7700E31, 60 * 40);
    vars.fundingStrategies[0] = new JarvisLiquidatorFunder();

    // all strategies need to be whitelisted
    vm.prank(vars.liquidator.owner());
    vars.liquidator._whitelistRedemptionStrategy(vars.fundingStrategies[0], true);
  }

  IFundsConversionStrategy[] fundingStrategies;
  bytes[] fundingDatas;

  IRedemptionStrategy[] redemptionStrategies;
  bytes[] redemptionDatas;

  CurveSwapLiquidator curveSwapLiquidator = new CurveSwapLiquidator();
  JarvisLiquidatorFunder jarvisLiquidator = new JarvisLiquidatorFunder();

  function addPolygonRedemptionStrategy(
    LiquidationData memory vars,
    IRedemptionStrategy strategy,
    string memory strategyContract,
    address inputToken
  ) internal returns (address) {
    bytes memory strategyData;
    address outputToken;

    if (compareStrings(strategyContract, "JarvisLiquidatorFunder")) {
      // TODO remove replacement when fixed
      strategy = jarvisLiquidator;
      (address syntheticToken, address collateralToken, address liquidityPool, uint256 expirationTime) = ap.jarvisPools(
        inputToken
      );
      outputToken = collateralToken;
      strategyData = abi.encode(syntheticToken, liquidityPool, expirationTime);
    } else if (compareStrings(strategyContract, "CurveSwapLiquidator")) {
      // TODO remove replacement when fixed
      strategy = curveSwapLiquidator;

      int128 outputIndex;
      int128 inputIndex;

      for (uint8 i = 0; i < curveSwapPools.length; i++) {
        CurveSwapPool memory csp = curveSwapPools[i];
        if (csp.pool == inputToken) {
          outputIndex = csp.preferredCoin;
          inputIndex = csp.preferredCoin == 0 ? int128(1) : int128(0);
          ICurvePool curvePool = ICurvePool(csp.pool);
          outputToken = curvePool.coins(outputIndex == 0 ? 0 : 1);
          break;
        }
      }

      strategyData = abi.encode(inputToken, inputIndex, outputIndex, outputToken, ap.getAddress("wtoken"));
    } else {
      revert("unknown collateral");
    }

    vars.liquidator._whitelistRedemptionStrategy(strategy, true);
    redemptionStrategies.push(strategy);
    redemptionDatas.push(strategyData);

    return outputToken;
  }

  function addPolygonStrategies(LiquidationData memory vars) internal {
    address debtToken = vars.debtMarket.underlying();

    uint256 i = 0;
    while (true) {
      emit log("debt token");
      emit log_address(debtToken);
      if (i++ > 10) revert("endless loop bad");
      IUniswapV2Router02 router = IUniswapV2Router02(uniswapRouter);

      (address addr, string memory contractInterface) = ap.fundingStrategies(debtToken);

      if (addr == address(0)) {
        address pairAddress = IUniswapV2Factory(router.factory()).getPair(debtToken, ap.getAddress("wtoken"));
        if (pairAddress != address(0)) {
          vars.flashSwapPair = IUniswapV2Pair(pairAddress);
          vars.flashSwapFundingToken = debtToken;
          break;
        } else {
          revert("no pair for flash swap");
        }
      } else {
        if (compareStrings(contractInterface, "JarvisLiquidatorFunder")) {
          (address syntheticToken, address collateralToken, address liquidityPool, uint256 expirationTime) = ap
            .jarvisPools(debtToken);

          debtToken = collateralToken;

          IFundsConversionStrategy strategy = new JarvisLiquidatorFunder();
          vars.liquidator._whitelistRedemptionStrategy(strategy, true);

          fundingStrategies.push(strategy);
          bytes memory strategyData = abi.encode(collateralToken, liquidityPool, expirationTime);
          fundingDatas.push(strategyData);
          // } else if (compareStrings(contractInterface, "SomeOtherFunder")) {
          // bytes memory strategyData = abi.encode(strategySpecificParams);
          // (IERC20Upgradeable inputToken, uint256 inputAmount) = IFundsConversionStrategy(addr).estimateInputAmount(10**(debtToken.decimals()), strategyData);
          // debtToken = inputToken;
          // fundingStrategies.push(new SomeOtherFunder());
        } else {
          revert("unknown polygon debt token");
        }
      }
    }

    vars.fundingStrategies = fundingStrategies;
    vars.fundingDatas = fundingDatas;

    // TODO
    if (vars.flashSwapFundingToken == ap.getAddress("wtoken")) {
      vars.flashSwapPair = IUniswapV2Pair(0x6e7a5FAFcec6BB1e78bAE2A1F0B612012BF14827); // FIRST_PAIR - USDC/WMATIC
    }
  }
}
