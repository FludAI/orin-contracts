require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

// The compiler settings below are the ones ORIN was deployed with. Changing
// the version, the optimizer runs or the EVM target changes the bytecode, and
// it will no longer match what is on Base.

// Optional fork setup, for reading the deployed contracts against mainnet
// state. FORK_URL defaults to the public mainnet.base.org; the pinned block is
// inside its state window, so no archive plan is needed. The only constraint
// is rate limiting, which any free-tier RPC key fixes.
// (base-rpc.publicnode.com returns 403 at this block.)
const FORK_BLOCK = Number(process.env.FORK_BLOCK || 48129024);

module.exports = {
  solidity: {
    version: "0.8.24",
    settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "cancun" },
  },
  networks: {
    hardhat: process.env.FORK
      ? {
          forking: { url: process.env.FORK_URL || "https://mainnet.base.org", blockNumber: FORK_BLOCK },
          chains: { 8453: { hardforkHistory: { shanghai: 0, cancun: 0 } } },
        }
      : {},
    // `base` intentionally has no accounts entry: this repo holds no key, and
    // nothing here is capable of sending a mainnet transaction.
    // Base mainnet only. On Base Sepolia the address 0xEd14… is mUSDC, not
    // wNEWS, so a Sepolia fork silently exercises the wrong token.
    base: { url: "https://mainnet.base.org", chainId: 8453 },
  },
  // Basescan source verification. One Etherscan v2 key covers Base; it is read
  // from the environment only and never stored in the repo.
  etherscan: { apiKey: process.env.ETHERSCAN_API_KEY || "" },
  sourcify: { enabled: false },
};
