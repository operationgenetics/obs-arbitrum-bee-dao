/**
 * Bind the real Roomie robot MCU credential - run once the humanoid robot and its hybrid PQC
 * MCU physically arrive.
 *
 *   PQC_PUBKEY_FILE=./roomie-pqc-pubkey.bin \
 *   MCU_ECDSA_SIGNER=0x... \
 *   OTS_CHAIN_TIP=0x... \
 *   OTS_CHAIN_LENGTH=1024 \
 *   node scripts/commission-robot.js
 *
 * WHAT GOES ON CHAIN: only public commitments.
 *   - keccak256 of the MCU's PQC public key
 *   - the MCU's secp256k1 address
 *   - the tip of the MCU's keccak256 one-time-signature chain
 *
 * WHAT NEVER GOES ON CHAIN: the biometric templates. They stay hard-locked inside the MCU
 * secure element on the robot and are never transmitted, exported or hashed on chain.
 */
const { ethers, ask, readOnlyDao, connectAsOrchestrator, ROOT } = require("./_common");
const fs = require("fs");
const path = require("path");

async function main() {
    const dao = readOnlyDao();
    if (!(await dao.isConfigUpdatable())) {
        throw new Error("Configuration is permanently immutable. The MCU can no longer be commissioned.");
    }

    const pubkeyFile = process.env.PQC_PUBKEY_FILE;
    if (!pubkeyFile) throw new Error("Set PQC_PUBKEY_FILE to the MCU's exported PQC public key file.");
    const resolved = path.isAbsolute(pubkeyFile) ? pubkeyFile : path.join(ROOT, pubkeyFile);
    const pubkey = fs.readFileSync(resolved);
    if (pubkey.length < 32) throw new Error(`PQC public key is only ${pubkey.length} bytes; expected a real PQC key.`);
    const pubkeyHash = ethers.keccak256(pubkey);

    const signer = ethers.getAddress(
        process.env.MCU_ECDSA_SIGNER || (() => { throw new Error("Set MCU_ECDSA_SIGNER to the MCU's secp256k1 address."); })()
    );
    const tip = process.env.OTS_CHAIN_TIP;
    if (!tip || !/^0x[0-9a-fA-F]{64}$/.test(tip)) throw new Error("Set OTS_CHAIN_TIP to the 32-byte chain tip (0x...).");
    const length = BigInt(process.env.OTS_CHAIN_LENGTH || "0");
    if (length <= 0n) throw new Error("Set OTS_CHAIN_LENGTH to the number of authorizations the chain can serve.");

    console.log("Commissioning the Roomie robot MCU");
    console.log(`  PQC public key   : ${resolved} (${pubkey.length} bytes)`);
    console.log(`  PQC key hash     : ${pubkeyHash}`);
    console.log(`  MCU ECDSA signer : ${signer}`);
    console.log(`  OTS chain tip    : ${tip}`);
    console.log(`  OTS chain length : ${length}`);
    console.log("\nBiometric templates are NOT part of this transaction and never leave the MCU.\n");
    console.log(`Each release will consume one chain link, so this credential authorizes at most ${length}`);
    console.log(`milestone releases (one per project per 60 days).\n`);

    if ((await ask("Send commissionRoomieRobot now? [y/N] ")).toLowerCase() !== "y") return;

    const dao2 = await connectAsOrchestrator("Commission Roomie robot MCU");
    const tx = await dao2.commissionRoomieRobot(pubkeyHash, signer, tip, length);
    console.log(`Transaction: ${tx.hash}`);
    await tx.wait();
    console.log("Roomie robot MCU commissioned. Milestone releases are now cryptographically possible.");
}

main().then(() => process.exit(0)).catch((e) => { console.error(e.message || e); process.exit(1); });
