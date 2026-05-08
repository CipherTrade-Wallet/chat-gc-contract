import "dotenv/config";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-verify";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: false,
    },
  },
  paths: {
    sources: "./contracts",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  networks: {
    hardhat: {
      chainId: 2632500,
    },
    "coti-mainnet": {
      url: process.env.COTI_RPC_URL ?? "https://mainnet.coti.io/rpc",
      chainId: 2632500,
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
    "coti-testnet": {
      url: process.env.COTI_TESTNET_RPC_URL ?? "https://testnet.coti.io/rpc",
      chainId: 7082400,
      accounts: process.env.DEPLOYER_PRIVATE_KEY ? [process.env.DEPLOYER_PRIVATE_KEY] : [],
    },
  },
  etherscan: {
    apiKey: {
      "coti-testnet": "placeholder",
      "coti-mainnet": "placeholder",
    },
    customChains: [
      {
        network: "coti-testnet",
        chainId: 7082400,
        urls: {
          apiURL: "https://testnet.cotiscan.io/api",
          browserURL: "https://testnet.cotiscan.io/",
        },
      },
      {
        network: "coti-mainnet",
        chainId: 2632500,
        urls: {
          apiURL: "https://mainnet.cotiscan.io/api",
          browserURL: "https://mainnet.cotiscan.io/",
        },
      },
    ],
  },
};

export default config;
