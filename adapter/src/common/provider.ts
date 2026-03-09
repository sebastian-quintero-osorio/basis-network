import { ethers } from "ethers";
import * as dotenv from "dotenv";

dotenv.config();

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:9650/ext/bc/C/rpc";
const PRIVATE_KEY = process.env.PRIVATE_KEY || "";

export function getProvider(): ethers.JsonRpcProvider {
  return new ethers.JsonRpcProvider(RPC_URL);
}

export function getSigner(): ethers.Wallet {
  const provider = getProvider();
  return new ethers.Wallet(PRIVATE_KEY, provider);
}

export function getContractAddress(name: string): string {
  const envKey = `${name}_ADDRESS`;
  const address = process.env[envKey];
  if (!address) {
    throw new Error(`Missing environment variable: ${envKey}`);
  }
  return address;
}
