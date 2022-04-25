// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;

import { ERC20 } from "solmate/tokens/ERC20.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "flywheel-v2/token/ERC20Gauges.sol";

import "../utils/TOUCHToken.sol";

// TODO integrate with FlywheelGaugeRewards
// TODO research ERC20VotesUpgradeable
contract VeMDSToken is ERC20Gauges {
  address public stakingController;

  constructor(
    uint32 _gaugeCycleLength,
    uint32 _incrementFreezeWindow,
    address _owner,
    Authority _authority,
    address _stakingController
  )
  ERC20Gauges(_gaugeCycleLength, _incrementFreezeWindow)
  Auth(_owner, _authority)
  ERC20("voting escrow MDS", "veMDS", 18)
  {
    stakingController = _stakingController; // TODO typed contract param
  }

  modifier onlyStakingController() {
    require(msg.sender == address(stakingController), "only the staking controller can mint");
    _;
  }

  /// @notice thrown when incrementing over a users free weight.
  error TransferNotSupported();

  function mint(address to, uint256 amount) public onlyStakingController {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) public onlyStakingController {
    _burn(from, amount);
  }

  function transfer(address, uint256) public virtual override returns (bool) {
    revert("Transfer not supported");
  }

  function transferFrom(
    address,
    address,
    uint256
  ) public virtual override returns (bool) {
    revert("Transfer not supported");
  }
}