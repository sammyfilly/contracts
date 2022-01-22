import { Contract, ContractFactory } from "ethers";
import { Interface } from "@ethersproject/abi";

import { OracleConf } from "../types";
import { Fuse } from "../../index";

export const getOracleConf = (fuse: Fuse, model: string, conf: OracleConf): OracleConf => {
  switch (model) {
    case "UniswapTwapPriceOracleV2": // Uniswap V2 TWAPs
      // Input validation
      if (!conf.uniswapV2Factory) conf.uniswapV2Factory = fuse.chainDeployment.UniswapTwapPriceOracleV2Factory;
      return conf;
    default:
      return conf;
  }
};

export const getDeployArgs = (fuse: Fuse, model: string, conf: OracleConf, options?: any) => {
  switch (model) {
    case "UniswapLpTokenPriceOracle":
      return [!!conf.useRootOracle];

    case "UniswapTwapPriceOracleV2": // Uniswap V2 TWAPs
      // Input Validation
      return [fuse.chainDeployment.UniswapTwapPriceOracleV2Root.address, conf.uniswapV2Factory];
    case "ChainlinkPriceOracleV2":
      return [conf.admin ? conf.admin : options.from, !!conf.canAdminOverwrite];
    case "FixedTokenPriceOracle":
      return [conf.baseToken];
    case "MasterPriceOracle":
      return [
        conf.underlyings ? conf.underlyings : [],
        conf.oracles ? conf.oracles : [],
        conf.defaultOracle ? conf.defaultOracle : "0x0000000000000000000000000000000000000000",
        conf.admin ? conf.admin : options.from,
        !!conf.canAdminOverwrite,
      ];
    default:
      return [];
  }
};

export const simpleDeploy = async (factory: ContractFactory, deployArgs: string[]) => {
  return await factory.deploy(...deployArgs);
};

export const deployMasterPriceOracle = async (fuse: Fuse, conf: OracleConf, deployArgs: string[], options: any) => {
  const initializableClones = new Contract(
    fuse.chainDeployment.InitializableClones.address,
    fuse.artifacts.initializableClones.abi,
    fuse.provider.getSigner()
  );
  const masterPriceOracle = new Interface(fuse.artifacts.MasterPriceOracle.abi.toString());
  const initializerData = masterPriceOracle.encodeDeploy(deployArgs);
  const receipt = await initializableClones.clone(fuse.chainDeployment.MasterPriceOracle.address, initializerData);
  return new Contract(receipt.events["Deployed"].returnValues.instance, fuse.artifacts.MasterPriceOracle.abi);
};