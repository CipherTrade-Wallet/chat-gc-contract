import { ethers } from "hardhat";

async function main() {
  const initialOwner =
    process.env.CHAT_GC_OWNER ?? process.env.DEPLOYER_ADDRESS ?? (await ethers.provider.getSigner(0).then((s) => s.address));
  const initialFeeRecipient = process.env.CHAT_GC_FEE_RECIPIENT ?? initialOwner;
  const initialFeeAmount = process.env.CHAT_GC_FEE_AMOUNT ?? "0";

  const ChatGC = await ethers.getContractFactory("ChatGC");
  // COTI RPC may not support "pending" block; pass gasLimit to skip estimateGas and avoid "pending block is not available"
  const chatGC = await ChatGC.deploy(initialOwner, initialFeeRecipient, BigInt(initialFeeAmount), {
    gasLimit: 8_000_000n,
  });

  await chatGC.waitForDeployment();
  const address = await chatGC.getAddress();

  console.log("ChatGC deployed to:", address);
  console.log("  owner:", initialOwner);
  console.log("  feeRecipient:", initialFeeRecipient);
  console.log("  feeAmount:", initialFeeAmount);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
