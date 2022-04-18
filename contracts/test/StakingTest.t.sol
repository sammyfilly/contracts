// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.4.23;

import "ds-test/test.sol";
import "forge-std/stdlib.sol";
import "forge-std/Vm.sol";
import "../gauges/VeMDSToken.sol";

contract StakingTest is DSTest {
  Vm public constant vm = Vm(HEVM_ADDRESS);

  VeMDSToken veToken;
  TOUCHToken govToken;

  event Transfer(address indexed from, address indexed to, uint256 amount);

  uint256 totalSupply = 100_000;

  function setUp() public {
    govToken = new TOUCHToken();
    veToken = new VeMDSToken(
      2, // gaugeCycleLength
      1, // incrementFreezeWindow
      address(this),
      Authority(address(0)),
      address(govToken)
    );
    govToken.initialize(totalSupply, veToken);
  }

  function testStaking(uint256 amountToStake) public {
    vm.assume(amountToStake > 0 && amountToStake < totalSupply);

    vm.warp(1);

    uint256 totalStakedBefore = govToken.totalStaked();
    uint256 stakerBalanceBefore = govToken.balanceOf(address(this));
    uint256 contractBalanceBefore = govToken.balanceOf(address(govToken));
    govToken.stake(amountToStake);

    {
      uint256 totalStakedAfter = govToken.totalStaked();
      uint256 stakerBalanceAfter = govToken.balanceOf(address(this));
      uint256 contractBalanceAfter = govToken.balanceOf(address(govToken));

      assert(stakerBalanceBefore - stakerBalanceAfter == amountToStake);
      assert(contractBalanceAfter - contractBalanceBefore == amountToStake);
      assert(totalStakedAfter - totalStakedBefore == amountToStake);
    }

    // advancing 1 day
    vm.warp(block.timestamp + 3600 * 24);
    govToken.claimAccumulatedVotingPower();
    assert(veToken.balanceOf(address(this)) == amountToStake * 1000 / 297625);

    {
      uint256 totalStakedAfter = govToken.totalStaked();
      uint256 stakerBalanceAfter = govToken.balanceOf(address(this));
      uint256 contractBalanceAfter = govToken.balanceOf(address(govToken));

      assert(stakerBalanceBefore - stakerBalanceAfter == amountToStake);
      assert(contractBalanceAfter - contractBalanceBefore == amountToStake);
      assert(totalStakedAfter - totalStakedBefore == amountToStake);
    }

    // advancing 7142 hours
    vm.warp(block.timestamp + 3600 * 7142);
    govToken.claimAccumulatedVotingPower();
    assert(veToken.balanceOf(address(this)) == amountToStake);
  }

  function testUnstaking(uint256 amountToStake, uint256 amountToUnstake) public {
    vm.assume(amountToStake > amountToUnstake && amountToStake < totalSupply);
    vm.assume(amountToUnstake > 0 && amountToUnstake < totalSupply);

    vm.warp(1);

    govToken.stake(amountToStake);

    // advancing 1 day
    vm.warp(block.timestamp + 3600 * 24);
    assert(veToken.balanceOf(address(this)) == 0);

    govToken.claimAccumulatedVotingPower();
    assert(veToken.balanceOf(address(this)) == amountToStake * 1000 / 297625);


    uint256 stakerBalanceBefore = govToken.balanceOf(address(this));
    uint256 contractBalanceBefore = govToken.balanceOf(address(govToken));
    uint256 totalStakedBefore = govToken.totalStaked();

    uint256 allTheVp = veToken.balanceOf(address(this));
    vm.expectEmit(true, true, true, false);
    emit Transfer(address(this), address(0), allTheVp);
    govToken.unstake(amountToUnstake);

    uint256 stakerBalanceAfter = govToken.balanceOf(address(this));
    uint256 contractBalanceAfter = govToken.balanceOf(address(govToken));
    uint256 totalStakedAfter = govToken.totalStaked();

    emit log_uint(contractBalanceBefore);
    emit log_uint(contractBalanceAfter);
    assertTrue(contractBalanceBefore - contractBalanceAfter == amountToUnstake, "contract balance incorrect after unstaking");
    assertTrue(stakerBalanceAfter - stakerBalanceBefore == amountToUnstake, "staker balance incorrect after unstaking");
    assertTrue(totalStakedBefore - totalStakedAfter == amountToUnstake, "total staked incorrect after unstaking");

    assert(govToken.accumulatedVotingPowerOf(address(this)) == 0);

    assert(govToken.stakeOf(address(this)) == amountToStake - amountToUnstake);
  }
}