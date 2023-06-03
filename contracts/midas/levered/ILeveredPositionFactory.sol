// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import { IRedemptionStrategy } from "../../liquidators/IRedemptionStrategy.sol";
import { ICErc20 } from "../../external/compound/ICErc20.sol";
import { LeveredPosition } from "./LeveredPosition.sol";
import { IFuseFeeDistributor } from "../../compound/IFuseFeeDistributor.sol";
import { ILiquidatorsRegistry } from "../../liquidators/registry/ILiquidatorsRegistry.sol";

import "openzeppelin-contracts-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";

interface ILeveredPositionFactoryStorage {
  function fuseFeeDistributor() external view returns (IFuseFeeDistributor);

  function liquidatorsRegistry() external view returns (ILiquidatorsRegistry);

  function blocksPerYear() external view returns (uint256);

  function owner() external view returns (address);
}

interface ILeveredPositionFactoryBase {
  function _setSlippages(
    IERC20Upgradeable[] calldata inputTokens,
    IERC20Upgradeable[] calldata outputTokens,
    uint256[] calldata slippages
  ) external;

  function _setLiquidatorsRegistry(ILiquidatorsRegistry _liquidatorsRegistry) external;

  function _setPairWhitelisted(
    ICErc20 _collateralMarket,
    ICErc20 _stableMarket,
    bool _whitelisted
  ) external;
}

interface ILeveredPositionFactoryExtension {
  function getRedemptionStrategies(IERC20Upgradeable inputToken, IERC20Upgradeable outputToken)
    external
    view
    returns (IRedemptionStrategy[] memory strategies, bytes[] memory strategiesData);

  function getMinBorrowNative() external view returns (uint256);

  function createPosition(ICErc20 _collateralMarket, ICErc20 _stableMarket) external returns (LeveredPosition);

  function createAndFundPosition(
    ICErc20 _collateralMarket,
    ICErc20 _stableMarket,
    IERC20Upgradeable _fundingAsset,
    uint256 _fundingAmount
  ) external returns (LeveredPosition);

  function createAndFundPositionAtRatio(
    ICErc20 _collateralMarket,
    ICErc20 _stableMarket,
    IERC20Upgradeable _fundingAsset,
    uint256 _fundingAmount,
    uint256 _leverageRatio
  ) external returns (LeveredPosition);

  function isFundingAllowed(IERC20Upgradeable inputToken, IERC20Upgradeable outputToken) external view returns (bool);

  function getSlippage(IERC20Upgradeable inputToken, IERC20Upgradeable outputToken) external view returns (uint256);

  function getPositionsByAccount(address account) external view returns (address[] memory);

  function getAccountsWithOpenPositions() external view returns (address[] memory);

  function getWhitelistedCollateralMarkets() external view returns (address[] memory);

  function getCollateralMarkets()
  external
  view
  returns (
    address[] memory markets,
    address[] memory poolOfMarket,
    address[] memory underlyings,
    string[] memory names,
    string[] memory symbols,
    uint8[] memory decimals,
    uint256[] memory totalUnderlyingSupplied,
    uint256[] memory ratesPerBlock
  );

  function getBorrowableMarketsByCollateral(ICErc20 _collateralMarket) external view returns (address[] memory);

  function getBorrowRateAtRatio(
    ICErc20 _collateralMarket,
    ICErc20 _stableMarket,
    uint256 _baseCollateral,
    uint256 _targetLeverageRatio
  ) external view returns (uint256);

  function getBorrowableMarketsAndRates(ICErc20 _collateralMarket)
  external
  view
  returns (
    address[] memory markets,
    address[] memory underlyings,
    string[] memory names,
    string[] memory symbols,
    uint256[] memory rates,
    uint8[] memory decimals
  );

  function getNetAPY(
    uint256 _supplyAPY,
    uint256 _supplyAmount,
    ICErc20 _collateralMarket,
    ICErc20 _stableMarket,
    uint256 _targetLeverageRatio
  ) external view returns (int256 netAPY);
}

interface ILeveredPositionFactory is ILeveredPositionFactoryStorage, ILeveredPositionFactoryBase, ILeveredPositionFactoryExtension {
}