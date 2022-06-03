// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "./helpers/WithPool.sol";
import "./config/BaseTest.t.sol";
import "forge-std/Test.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { FuseFlywheelDynamicRewards } from "fuse-flywheel/rewards/FuseFlywheelDynamicRewards.sol";
import { MockERC20 } from "solmate/test/utils/mocks/MockERC20.sol";
import { ICToken } from "../external/compound/ICToken.sol";
import { MasterPriceOracle } from "../oracles/MasterPriceOracle.sol";
import { IRedemptionStrategy } from "../liquidators/IRedemptionStrategy.sol";
import { IUniswapV2Router02 } from "../external/uniswap/IUniswapV2Router02.sol";
import { IComptroller } from "../external/compound/IComptroller.sol";
import { FusePoolLensSecondary } from "../FusePoolLensSecondary.sol";

interface MockXBomb {
  function getExchangeRate() external returns (uint256);
}

contract MockBnb is MockERC20 {
  constructor() MockERC20("test", "test", 8) {}

  function deposit() external payable {}
}

contract BombE2eTest is WithPool, BaseTest {
  using stdStorage for StdStorage;
  StdStorage internal stdstore;

  constructor()
    WithPool(
      MasterPriceOracle(0xB641c21124546e1c979b4C1EbF13aB00D43Ee8eA),
      MockERC20(0x522348779DCb2911539e76A1042aA922F9C47Ee3)
    )
  {}

  function setUp() public shouldRun(forChains(BSC_MAINNET)) {
    vm.prank(0xcd6cD62F11F9417FBD44dc0a44F891fd3E869234);
    underlyingToken.mint(address(this), 100e18);
    setUpPool("bsc-test", false, 0.1e18, 1.1e18);
  }

  function testDeployCErc20Delegate() public shouldRun(forChains(BSC_MAINNET)) {
    vm.roll(1);
    deployCErc20Delegate(address(underlyingToken), "cUnderlyingToken", "CUT", 0.9e18);

    CToken[] memory allMarkets = comptroller.getAllMarkets();
    CErc20Delegate cToken = CErc20Delegate(address(allMarkets[allMarkets.length - 1]));
    assertEq(cToken.name(), "cUnderlyingToken");
    underlyingToken.approve(address(cToken), 1e36);
    address[] memory cTokens = new address[](1);
    cTokens[0] = address(cToken);
    comptroller.enterMarkets(cTokens);

    vm.roll(1);
    cToken.mint(10e18);
    assertEq(cToken.totalSupply(), 10e18 * 5);
    assertEq(underlyingToken.balanceOf(address(cToken)), 10e18);

    cToken.borrow(1000);
    assertEq(cToken.totalBorrows(), 1000);
    assertEq(underlyingToken.balanceOf(address(this)), 100e18 - 10e18 + 1000);
  }

  function testGetPoolAssetsData() public shouldRun(forChains(BSC_MAINNET)) {
    vm.roll(1);
    deployCErc20Delegate(address(underlyingToken), "cUnderlyingToken", "CUT", 0.9e18);

    CToken[] memory allMarkets = comptroller.getAllMarkets();
    CErc20Delegate cToken = CErc20Delegate(address(allMarkets[allMarkets.length - 1]));
    assertEq(cToken.name(), "cUnderlyingToken");
    underlyingToken.approve(address(cToken), 1e36);
    address[] memory cTokens = new address[](1);
    cTokens[0] = address(cToken);
    comptroller.enterMarkets(cTokens);

    cToken.mint(10e18);

    FusePoolLens.FusePoolAsset[] memory assets = poolLens.getPoolAssetsWithData(IComptroller(address(comptroller)));

    assertEq(assets[0].supplyBalance, 10e18);
  }

  function testCErc20Liquidation() public shouldRun(forChains(BSC_MAINNET)) {
    vm.roll(1);
    MockERC4626 erc4626 = MockERC4626(0x92C6C8278509A69f5d601Eea1E6273F304311bFe);
    MockBnb bnb = MockBnb(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    deployCErc20PluginDelegate(erc4626, 0.9e18);
    deployCErc20Delegate(address(bnb), "BNB", "bnb", 0.9e18);

    CToken[] memory allMarkets = comptroller.getAllMarkets();
    CErc20PluginDelegate cToken = CErc20PluginDelegate(address(allMarkets[0]));

    cToken._setImplementationSafe(address(cErc20PluginDelegate), false, abi.encode(address(erc4626)));

    CErc20Delegate cBnbToken = CErc20Delegate(address(allMarkets[1]));

    address[] memory cTokens = new address[](2);
    cTokens[0] = address(cToken);
    cTokens[1] = address(cBnbToken);
    comptroller.enterMarkets(cTokens);

    // setting up liquidator
    liquidator = new FuseSafeLiquidator();
    liquidator.initialize(
      0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
      0x10ED43C718714eb63d5aA57B78B54704E256024E,
      0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56,
      0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c,
      "0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5"
    );
    address accountOne = address(1);
    address accountTwo = address(2);

    FusePoolLensSecondary secondary = new FusePoolLensSecondary();
    secondary.initialize(fusePoolDirectory);

    vm.prank(0xcd6cD62F11F9417FBD44dc0a44F891fd3E869234);
    underlyingToken.mint(accountTwo, 1000000000000e18);
    // Account One Supply
    vm.deal(accountOne, 1000000000000e18);
    vm.startPrank(accountOne);
    bnb.deposit{ value: 1000000000000e18 }();
    vm.stopPrank();

    // Account One Supply
    vm.startPrank(accountOne);
    bnb.approve(address(cBnbToken), 1e36);
    cBnbToken.mint(1e17);
    vm.stopPrank();

    // Account Two Supply
    vm.startPrank(accountTwo);
    underlyingToken.approve(address(cToken), 1e36);
    cToken.mint(10e18);
    vm.stopPrank();
    assertEq(cToken.totalSupply(), 10e18 * 5);
    assertEq(cBnbToken.totalSupply(), 1e17 * 5);

    // Account One Borrow
    vm.startPrank(accountOne);
    underlyingToken.approve(address(cToken), 1e36);
    cToken.borrow(100);
    vm.stopPrank();
    assertEq(cToken.totalBorrows(), 100);
    uint256 price1 = priceOracle.getUnderlyingPrice(ICToken(address(cToken)));
    vm.mockCall(
      0xB641c21124546e1c979b4C1EbF13aB00D43Ee8eA,
      abi.encodeWithSelector(priceOracle.getUnderlyingPrice.selector, ICToken(address(cToken))),
      abi.encode(price1 * 1000)
    );

    IRedemptionStrategy[] memory strategies = new IRedemptionStrategy[](0);
    bytes[] memory abis = new bytes[](0);

    vm.startPrank(accountOne);
    FusePoolLens.FusePoolAsset[] memory assetsData = poolLens.getPoolAssetsWithData(IComptroller(address(comptroller)));
    uint256 bnbBalance = cBnbToken.balanceOf(accountOne);

    liquidator.safeLiquidateToTokensWithFlashLoan(
      accountOne,
      9,
      ICErc20(address(cToken)),
      ICErc20(address(cBnbToken)),
      0,
      address(0),
      IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E),
      IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E),
      strategies,
      abis,
      0
    );

    FusePoolLens.FusePoolAsset[] memory assetsDataAfter = poolLens.getPoolAssetsWithData(
      IComptroller(address(comptroller))
    );

    uint256 bnbBalanceAfter = cBnbToken.balanceOf(accountOne);

    assertGt(bnbBalance, bnbBalanceAfter);
    assertGt(assetsData[1].supplyBalance, assetsDataAfter[1].supplyBalance);

    vm.stopPrank();
  }

  function testDeployCErc20PluginDelegate() public shouldRun(forChains(BSC_MAINNET)) {
    MockERC4626 erc4626 = MockERC4626(0x92C6C8278509A69f5d601Eea1E6273F304311bFe);

    vm.roll(1);
    deployCErc20PluginDelegate(erc4626, 0.9e18);

    CToken[] memory allMarkets = comptroller.getAllMarkets();
    CErc20PluginDelegate cToken = CErc20PluginDelegate(address(allMarkets[allMarkets.length - 1]));

    cToken._setImplementationSafe(address(cErc20PluginDelegate), false, abi.encode(address(erc4626)));
    assertEq(address(cToken.plugin()), address(erc4626));

    underlyingToken.approve(address(cToken), 1e36);
    address[] memory cTokens = new address[](1);
    cTokens[0] = address(cToken);
    comptroller.enterMarkets(cTokens);
    vm.roll(1);

    cToken.mint(10e18);
    assertEq(cToken.totalSupply(), 10e18 * 5);
    uint256 exchangeRate = MockXBomb(0xAf16cB45B8149DA403AF41C63AbFEBFbcd16264b).getExchangeRate();
    uint256 balance = erc4626.balanceOf(address(cToken));
    uint256 convertedRate = (balance * exchangeRate) / 1e18;
    uint256 offset = 10;
    assertGt(convertedRate, 10e18 - offset);
    vm.roll(1);

    cToken.borrow(1000);
    assertEq(cToken.totalBorrows(), 1000);
    balance = erc4626.balanceOf(address(cToken));
    convertedRate = (balance * exchangeRate) / 1e18;
    assertGt(convertedRate, 10e18 - 1000 - offset);
    assertEq(underlyingToken.balanceOf(address(this)), 100e18 - 10e18 + 1000);
  }

  function testDeployCErc20PluginRewardsDelegate() public shouldRun(forChains(BSC_MAINNET)) {
    MockERC20 rewardToken = new MockERC20("RewardToken", "RT", 18);
    FuseFlywheelDynamicRewards rewards;
    FuseFlywheelCore flywheel = new FuseFlywheelCore(
      underlyingToken,
      IFlywheelRewards(address(0)),
      IFlywheelBooster(address(0)),
      address(this),
      Authority(address(0))
    );
    rewards = new FuseFlywheelDynamicRewards(flywheel, 1);
    flywheel.setFlywheelRewards(rewards);

    MockERC4626Dynamic mockERC4626Dynamic = new MockERC4626Dynamic(
      ERC20(address(underlyingToken)),
      FlywheelCore(address(flywheel))
    );

    ERC20 marketKey = ERC20(address(mockERC4626Dynamic));
    flywheel.addStrategyForRewards(marketKey);

    vm.roll(1);
    deployCErc20PluginRewardsDelegate(mockERC4626Dynamic, flywheel, 0.9e18);

    CToken[] memory allMarkets = comptroller.getAllMarkets();
    CErc20PluginRewardsDelegate cToken = CErc20PluginRewardsDelegate(address(allMarkets[allMarkets.length - 1]));

    cToken._setImplementationSafe(
      address(cErc20PluginRewardsDelegate),
      false,
      abi.encode(address(mockERC4626Dynamic), address(flywheel), address(underlyingToken))
    );
    assertEq(address(cToken.plugin()), address(mockERC4626Dynamic));
    assertEq(underlyingToken.allowance(address(cToken), address(mockERC4626Dynamic)), type(uint256).max);
    assertEq(underlyingToken.allowance(address(cToken), address(flywheel)), 0);

    cToken.approve(address(rewardToken), address(flywheel));
    assertEq(rewardToken.allowance(address(cToken), address(flywheel)), type(uint256).max);

    underlyingToken.approve(address(cToken), 1e36);
    address[] memory cTokens = new address[](1);
    cTokens[0] = address(cToken);
    comptroller.enterMarkets(cTokens);
    vm.roll(1);

    cToken.mint(10000000);
    assertEq(cToken.totalSupply(), 10000000 * 5);
    assertEq(mockERC4626Dynamic.balanceOf(address(cToken)), 10000000);
    assertEq(underlyingToken.balanceOf(address(mockERC4626Dynamic)), 10000000);
    vm.roll(1);

    cToken.borrow(1000);
    assertEq(cToken.totalBorrows(), 1000);
    assertEq(underlyingToken.balanceOf(address(mockERC4626Dynamic)), 10000000 - 1000);
    assertEq(mockERC4626Dynamic.balanceOf(address(cToken)), 10000000 - 1000);
    assertEq(underlyingToken.balanceOf(address(this)), 100e18 - 10000000 + 1000);
  }
}