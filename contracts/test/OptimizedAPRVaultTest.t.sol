// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import { BaseTest } from "./config/BaseTest.t.sol";
import "../midas/vault/MultiStrategyVault.sol";
import "../midas/strategies/CompoundMarketERC4626.sol";
import { ICErc20 } from "../external/compound/ICErc20.sol";

import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { IERC4626Upgradeable as IERC4626, IERC20Upgradeable as IERC20 } from "openzeppelin-contracts-upgradeable/contracts/interfaces/IERC4626Upgradeable.sol";
import "../midas/vault/OptimizerAPRStrategy.sol";
import "./ExtensionsTest.sol";

contract OptimizedAPRVaultTest is ExtensionsTest {
  function testVaultOptimization() public debuggingOnly fork(BSC_MAINNET) {
    address wnativeAddress = ap.getAddress("wtoken");
    address ankrWbnbMarketAddress = 0x57a64a77f8E4cFbFDcd22D5551F52D675cc5A956;
    address ahWbnbMarketAddress = 0x059c595f19d6FA9f8203F3731DF54455cD248c44;
    ICErc20 ankrWbnbMarket = ICErc20(ankrWbnbMarketAddress);
    ICErc20 ahWbnbMarket = ICErc20(ahWbnbMarketAddress);

    _upgradeExistingCTokenExtension(CErc20Delegate(ankrWbnbMarketAddress));
    _upgradeExistingCTokenExtension(CErc20Delegate(ahWbnbMarketAddress));

    OptimizerAPRStrategy vault = new OptimizerAPRStrategy();
    {
      TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(vault), address(dpa), "");
      vault = OptimizerAPRStrategy(address(proxy));
    }

    CompoundMarketERC4626 ankrMarketAdapter = new CompoundMarketERC4626();
    {
      TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(ankrMarketAdapter), address(dpa), "");
      ankrMarketAdapter = CompoundMarketERC4626(address(proxy));
    }
    ankrMarketAdapter.initialize(
      ankrWbnbMarket,
      address(vault),
      20 * 24 * 365 * 60 //blocks per year
    );
    uint256 ankrMarketApr = ankrMarketAdapter.apr();
    emit log_named_uint("ankrMarketApr", ankrMarketApr);

    CompoundMarketERC4626 ahMarketAdapter = new CompoundMarketERC4626();
    {
      TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(ahMarketAdapter), address(dpa), "");
      ahMarketAdapter = CompoundMarketERC4626(address(proxy));
    }
    ahMarketAdapter.initialize(
      ahWbnbMarket,
      address(vault),
      20 * 24 * 365 * 60 //blocks per year
    );
    uint256 ahMarketApr = ahMarketAdapter.apr();
    emit log_named_uint("ahMarketApr", ahMarketApr);

    AdapterConfig[10] memory adapters;
    adapters[0].adapter = ankrMarketAdapter;
    adapters[0].allocation = 9e17;
    adapters[1].adapter = ahMarketAdapter;
    adapters[1].allocation = 1e17;

    vault.initialize(
      IERC20(wnativeAddress),
      adapters,
      2, // adapters count
      VaultFees(0, 0, 0, 0),
      address(this),
      type(uint256).max
    );

    address wbnbWhale = 0x0eD7e52944161450477ee417DE9Cd3a859b14fD0;

    vm.startPrank(wbnbWhale);
    IERC20(wnativeAddress).approve(address(vault), type(uint256).max);
    vault.deposit(1e18);
    vm.stopPrank();

    uint64[] memory lenderSharesHint = new uint64[](2);
    lenderSharesHint[0] = 4e17;
    lenderSharesHint[1] = 6e17;

    uint256 lentTotalAssets = vault.lentTotalAssets();
    uint256 estimatedTotalAssets = vault.estimatedTotalAssets();
    uint256 currentAPR = vault.estimatedAPR();
    emit log_named_uint("lentTotalAssets", lentTotalAssets);
    emit log_named_uint("estimatedTotalAssets", estimatedTotalAssets);
    emit log_named_uint("currentAPR", currentAPR);

    uint256 estimatedAprHint;
    int256[] memory lenderAdjustedAmounts;
    if (lenderSharesHint.length != 0) (estimatedAprHint, lenderAdjustedAmounts) = vault.estimatedAPR(lenderSharesHint);

    emit log_named_int("lenderAdjustedAmounts0", lenderAdjustedAmounts[0]);
    emit log_named_int("lenderAdjustedAmounts1", lenderAdjustedAmounts[1]);
    emit log_named_uint("hint", estimatedAprHint);

    if (estimatedAprHint > currentAPR) {
      emit log("harvest will rebalance");
    } else {
      emit log("harvest will NOT rebalance");
    }

    vault.harvest(lenderSharesHint);

    uint256 aprAfter = vault.estimatedAPR();
    emit log_named_uint("aprAfter", aprAfter);

    assertGt(aprAfter, currentAPR, "!harvest didn't optimize the allocations");
  }
}