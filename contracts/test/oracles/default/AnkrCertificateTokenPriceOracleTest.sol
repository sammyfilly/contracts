// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import { BaseTest } from "../../config/BaseTest.t.sol";
import { AnkrCertificateTokenPriceOracle } from "../../../oracles/default/AnkrCertificateTokenPriceOracle.sol";
import { MasterPriceOracle } from "../../../oracles/MasterPriceOracle.sol";
import { ICToken } from "../../../external/compound/ICToken.sol";

contract AnkrCertificateTokenPriceOracleTest is BaseTest {
  AnkrCertificateTokenPriceOracle private oracle;

  address aFTMc = 0xCfC785741Dc0e98ad4c9F6394Bb9d43Cd1eF5179;
  address aBNBc = 0xE85aFCcDaFBE7F2B096f268e31ccE3da8dA2990A;

  function testAnkrFTMOracle() public forkAtBlock(FANTOM_OPERA, 50767474) {
    setUpOracleFtm();
    ankrFTM();
  }

  function testAnkrBSCOracle() public forkAtBlock(BSC_MAINNET, 22967648) {
    setUpOracleBsc();
    ankrBSC();
  }

  function setUpOracleFtm() public {
    oracle = new AnkrCertificateTokenPriceOracle();
    oracle.initialize(aFTMc);
  }

  function setUpOracleBsc() public {
    oracle = new AnkrCertificateTokenPriceOracle();
    oracle.initialize(aBNBc);
  }

  function ankrFTM() public {
    uint256 priceAnkrFTMc = oracle.price(aFTMc);

    assertGt(priceAnkrFTMc, 1e18);
    assertEq(priceAnkrFTMc, 1031771264536613055);
  }

  function ankrBSC() public {
    uint256 priceAnkrBNBc = oracle.price(aBNBc);

    assertGt(priceAnkrBNBc, 1e18);
    assertEq(priceAnkrBNBc, 1036531403670513817);
  }
}
