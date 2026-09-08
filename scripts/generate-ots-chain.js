/**
 * Generates the post-quantum one-time-signature hash chain for the Roomie MCU.
 *
 *   node scripts/generate-ots-chain.js [length]
 *
 * IN PRODUCTION the seed must be generated INSIDE the MCU secure element and never leave it.
 * This script exists to (a) show the exact construction the contract verifies and (b) let you
 * derive the publishable tip from a seed the MCU gives you.
 *
 *   s_0 = seed (secret, MCU only)
 *   s_i = keccak256(abi.encodePacked(s_{i-1}))
 *   tip = s_N  <- published on chain
 *
 * Each authorization reveals s_{N-1}, s_{N-2}, ... in order. The contract checks
 * keccak256(preimage) == storedTip and then advances the tip to the revealed value, which makes
 * every link single-use and forward-secure. Security rests on keccak256 pre-image resistance,
 * which Shor's algorithm does not break.
 */
const { ethers } = require("ethers");

const length = Number(process.argv[2] || 1024);
if (!Number.isInteger(length) || length < 1 || length > 100000) {
    console.error("Length must be an integer between 1 and 100000.");
    process.exit(1);
}

const seed = process.env.OTS_SEED || ethers.hexlify(ethers.randomBytes(32));
let current = seed;
for (let i = 0; i < length; i++) {
    current = ethers.keccak256(current);
}

console.log("Roomie MCU one-time-signature chain");
console.log(`  seed (SECRET - keep inside the MCU) : ${seed}`);
console.log(`  length                              : ${length}`);
console.log(`  tip  (publish on chain)             : ${current}`);
console.log("\nCommission with:");
console.log(`  OTS_CHAIN_TIP=${current} OTS_CHAIN_LENGTH=${length} node scripts/commission-robot.js`);
