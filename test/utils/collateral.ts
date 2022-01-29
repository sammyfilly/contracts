import { BigNumber, constants, Contract, utils } from "ethers";
import { ERC20Abi, Fuse, USDPricedFuseAsset } from "../../lib/esm/src";
import { assetInPool, getPoolIndex } from "./pool";
import { HardhatEthersHelpers } from "@nomiclabs/hardhat-ethers/types";
import { expect } from "chai";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

async function getAsset(
  ethers: HardhatEthersHelpers,
  sdk: Fuse,
  poolAddress: string,
  underlyingSymbol: string
): Promise<USDPricedFuseAsset> {
  const poolId = (await getPoolIndex(poolAddress, sdk)).toString();
  const assetsInPool = await sdk.fetchFusePoolData(poolId);
  return assetsInPool.assets.filter((a) => a.underlyingSymbol === underlyingSymbol)[0];
}

function getCToken(asset: USDPricedFuseAsset, sdk: Fuse, signer: SignerWithAddress) {
  if (asset.underlyingToken === constants.AddressZero) {
    return new Contract(asset.cToken, sdk.chainDeployment.CEtherDelegate.abi, signer);
  } else {
    return new Contract(asset.cToken, sdk.chainDeployment.CErc20Delegate.abi, signer);
  }
}

export async function addCollateral(
  ethers: HardhatEthersHelpers,
  poolAddress: string,
  depositorAddress: string,
  underlyingSymbol: string,
  amount: string
) {
  let tx;
  let amountBN;
  let cToken;

  const signer = await ethers.getSigner(depositorAddress);
  const sdk = new Fuse(ethers.provider, "1337");

  const assetToDeploy = await getAsset(ethers, sdk, poolAddress, underlyingSymbol);
  // const assetCtc = new Contract(assetToDeploy.underlyingToken, ERC20Abi, signer);
  // tx = await assetCtc.approve(assetToDeploy.cToken, BigNumber.from(2).pow(BigNumber.from(256)).sub(constants.One));

  cToken = getCToken(assetToDeploy, sdk, signer);
  const pool = await ethers.getContractAt("Comptroller", poolAddress, signer);
  tx = await pool.enterMarkets([assetToDeploy.cToken]);
  await tx.wait();
  amountBN = utils.parseUnits(amount, 18);
  await approveAndMint(amountBN, cToken, assetToDeploy.underlyingToken, signer);
}

export async function approveAndMint(
  amount: BigNumber,
  cTokenContract: Contract,
  underlyingToken: string,
  signer: SignerWithAddress
) {
  let tx;

  if (underlyingToken === constants.AddressZero) {
    tx = await cTokenContract.approve(signer.address, BigNumber.from(2).pow(BigNumber.from(256)).sub(constants.One));
    await tx.wait();
    tx = await cTokenContract.mint({ value: amount, from: signer.address });
  } else {
    const assetContract = new Contract(underlyingToken, ERC20Abi, signer);
    tx = await assetContract.approve(
      cTokenContract.address,
      BigNumber.from(2).pow(BigNumber.from(256)).sub(constants.One)
    );
    await tx.wait();
    tx = await cTokenContract.mint(amount);
  }
  return tx.wait();
}

export async function borrowCollateral(
  ethers: HardhatEthersHelpers,
  poolAddress: string,
  borrowerAddress: string,
  underlyingSymbol: string,
  amount: string
) {
  let tx;
  let rec;

  const signer = await ethers.getSigner(borrowerAddress);
  const sdk = new Fuse(ethers.provider, "1337");
  const assetToDeploy = await getAsset(ethers, sdk, poolAddress, underlyingSymbol);

  const pool = await ethers.getContractAt("Comptroller", poolAddress, signer);
  tx = await pool.enterMarkets([assetToDeploy.cToken]);
  await tx.wait();

  const cToken = getCToken(assetToDeploy, sdk, signer);
  tx = await cToken.callStatic.borrow(utils.parseUnits(amount, 18));
  expect(tx).to.eq(0);
  tx = await cToken.borrow(utils.parseUnits(amount, 18));
  rec = await tx.wait();
  expect(rec.status).to.eq(1);
  const poolId = await getPoolIndex(poolAddress, sdk);
  const assetAfterBorrow = await assetInPool(poolId, sdk, assetToDeploy.underlyingSymbol);
  console.log(assetAfterBorrow.borrowBalanceUSD, "Borrow Balance USD: AFTER mint & borrow");
  console.log(assetAfterBorrow.supplyBalanceUSD, "Supply Balance USD: AFTER mint & borrow");
}
