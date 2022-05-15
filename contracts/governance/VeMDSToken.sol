// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;

import { ERC20 } from "solmate/tokens/ERC20.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/ERC20/IERC20Upgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "flywheel-v2/token/ERC20Gauges.sol";
import "flywheel-v2/token/ERC20MultiVotes.sol";

import "../utils/TOUCHToken.sol";
import "../external/compound/ICToken.sol";

// TODO integrate with FlywheelGaugeRewards - deploy FlywheelGaugeRewards and provide VeMDSToken as param
// TODO research ERC20VotesUpgradeable, ERC20MultiVotes
contract VeMDSToken is ERC20Gauges, ERC20MultiVotes {
  address public stakingController;
  EnumerableSet.AddressSet internal _markets;

  constructor(
    uint32 _gaugeCycleLength,
    uint32 _incrementFreezeWindow,
    address _owner,
    Authority _authority,
    address _stakingController
  )
  ERC20Gauges(_gaugeCycleLength, _incrementFreezeWindow)
  Auth(_owner, _authority)
  ERC20("Voting Escrow MDS", "veMDS", 18)
  {
    stakingController = _stakingController; // TODO typed contract param
  }
  // TODO ability for the DAO address to be changed by the DAO

  modifier onlyStakingController() {
    require(msg.sender == address(stakingController), "only the staking controller can mint");
    _;
  }

  error TransferNotSupported();

  // TODO make exceptions to mint, burn, transfer(From) for bridging
  function mint(address to, uint256 amount) public onlyStakingController {
    _mint(to, amount);
  }

  function burn(address from, uint256 amount) public onlyStakingController {
    _burn(from, amount);
  }

  function _burn(address from, uint256 amount)
  internal
  virtual
  override(ERC20Gauges, ERC20MultiVotes)
  {
    _decrementWeightUntilFree(from, amount);
    _decrementVotesUntilFree(from, amount);
    ERC20._burn(from, amount);
  }

  function transfer(address, uint256) public virtual override(ERC20Gauges, ERC20MultiVotes) returns (bool) {
    revert TransferNotSupported();
  }

  function transferFrom(
    address,
    address,
    uint256
  ) public virtual override(ERC20Gauges, ERC20MultiVotes) returns (bool) {
    revert TransferNotSupported();
  }
}
