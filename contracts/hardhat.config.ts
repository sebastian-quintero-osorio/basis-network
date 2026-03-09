import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000001";
const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:9650/ext/bc/C/rpc";
const CHAIN_ID = parseInt(process.env.CHAIN_ID || "43199");

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      evmVersion: "cancun",
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
    },
    basisLocal: {
      url: RPC_URL,
      chainId: CHAIN_ID,
      accounts: [PRIVATE_KEY],
    },
    basisFuji: {
      url: process.env.FUJI_RPC_URL || "",
      chainId: CHAIN_ID,
      accounts: [PRIVATE_KEY],
    },
  },
};

export default config;
