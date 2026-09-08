/**
 * Submit one robot-authorized milestone release.
 *
 * This is the ONLY path by which OBS can ever leave the vault, and it is the reference
 * implementation of the digest the Roomie MCU must sign.
 *
 *   PROJECT_ID=1 AMOUNT=1000 \
 *   ATTESTATION_FILE=./attestation.json \
 *   PQC_PUBKEY_FILE=./roomie-pqc-pubkey.bin \
 *   PQC_SIGNATURE_FILE=./roomie-milestone.sig \
 *   MCU_ECDSA_SIGNATURE=0x... \
 *   OTS_PREIMAGE=0x... \
 *   node scripts/authorize-milestone.js
 *
 * attestation.json - the robot's real-world evidence, every field mandatory:
 *   {
 *     "acresSecured": 25, "hivesInstalled": 40, "honeyKgDistributedFree": 120,
 *     "atmosphericWaterLiters": 9000, "solarKwhGenerated": 4200, "batteryKwhStored": 800,
 *     "beeFlourishingIndexDelta": 10000,
 *     "offGridVerified": true, "landAcquired": true, "equipmentOperational": true,
 *     "evidenceHash": "0x..."
 *   }
 *
 * Run with DRY_RUN=1 to print the digest the MCU must sign and stop. That is the normal first
 * step: the MCU signs the printed digest (with biometric consent, checked on the MCU itself),
 * you paste the result into MCU_ECDSA_SIGNATURE, then run again for real.
 */
const { ethers, ask, readOnlyDao, connectAsOrchestrator, ROOT } = require("./_common");
const fs = require("fs");
const path = require("path");

const ATTESTATION_FIELDS = [
    ["acresSecured", "uint"], ["hivesInstalled", "uint"], ["honeyKgDistributedFree", "uint"],
    ["atmosphericWaterLiters", "uint"], ["solarKwhGenerated", "uint"], ["batteryKwhStored", "uint"],
    ["beeFlourishingIndexDelta", "uint"], ["offGridVerified", "bool"], ["landAcquired", "bool"],
    ["equipmentOperational", "bool"], ["evidenceHash", "bytes32"]
];

function resolveFile(envName) {
    const v = process.env[envName];
    if (!v) throw new Error(`Set ${envName}.`);
    return fs.readFileSync(path.isAbsolute(v) ? v : path.join(ROOT, v));
}

function loadAttestation() {
    const raw = JSON.parse(resolveFile("ATTESTATION_FILE").toString("utf8"));
    const out = {};
    for (const [name, kind] of ATTESTATION_FIELDS) {
        if (raw[name] === undefined) throw new Error(`attestation is missing "${name}"`);
        out[name] = kind === "uint" ? BigInt(raw[name]) : raw[name];
    }
    // Fail locally on anything the contract's hardcoded mission rules would reject on chain.
    const rules = [
        [out.offGridVerified === true, "site must be fully off-grid"],
        [out.solarKwhGenerated > 0n, "solar generation required"],
        [out.batteryKwhStored > 0n, "battery storage required"],
        [out.atmosphericWaterLiters > 0n, "atmospheric water generation required"],
        [out.honeyKgDistributedFree > 0n, "free honey distribution required"],
        [out.hivesInstalled > 0n, "indoor bee habitat hives required"],
        [out.landAcquired === true, "land must be acquired/held"],
        [out.equipmentOperational === true, "maintenance equipment must be operational"],
        [/^0x[0-9a-fA-F]{64}$/.test(out.evidenceHash) && BigInt(out.evidenceHash) !== 0n, "robot evidence bundle required"]
    ];
    for (const [ok, why] of rules) if (!ok) throw new Error(`Mission rule violated: ${why}`);
    return out;
}

function attestationHash(a) {
    return ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
            ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "bool", "bool", "bool", "bytes32"],
            [a.acresSecured, a.hivesInstalled, a.honeyKgDistributedFree, a.atmosphericWaterLiters,
             a.solarKwhGenerated, a.batteryKwhStored, a.beeFlourishingIndexDelta,
             a.offGridVerified, a.landAcquired, a.equipmentOperational, a.evidenceHash]
        )
    );
}

async function main() {
    const dao = readOnlyDao();
    const daoAddr = await dao.getAddress();
    const projectId = BigInt(process.env.PROJECT_ID || (() => { throw new Error("Set PROJECT_ID."); })());
    const amount = ethers.parseUnits(process.env.AMOUNT || (() => { throw new Error("Set AMOUNT (in whole OBS)."); })(), 18);

    if (!(await dao.isVaultUnlocked())) throw new Error("Vault is locked: the OBS bonding curve has not reached 5,000,000,000 DAI.");
    if (!(await dao.isRobotCommissioned())) throw new Error("Roomie robot MCU is not commissioned.");

    const unlockAt = await dao.nextMilestoneUnlockTime(projectId);
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (now < unlockAt) {
        throw new Error(`Milestone locked until ${new Date(Number(unlockAt) * 1000).toISOString()} (one authorization per project per 60 days).`);
    }

    const attestation = loadAttestation();
    const pqcPublicKey = resolveFile("PQC_PUBKEY_FILE");
    const pqcSignature = resolveFile("PQC_SIGNATURE_FILE");
    if (pqcSignature.length < 512) throw new Error(`PQC signature is ${pqcSignature.length} bytes; the contract requires at least 512.`);

    const onChainKeyHash = await dao.getRobotPqcPublicKeyHash();
    if (ethers.keccak256(pqcPublicKey) !== onChainKeyHash) {
        throw new Error(`PQC public key does not match the on-chain commitment ${onChainKeyHash}.`);
    }

    const otsPreimage = process.env.OTS_PREIMAGE;
    if (!otsPreimage || !/^0x[0-9a-fA-F]{64}$/.test(otsPreimage)) throw new Error("Set OTS_PREIMAGE to the next 32-byte chain link.");
    const expectedTip = await dao.getRobotOtsChainTip();
    if (ethers.keccak256(otsPreimage) !== expectedTip) {
        throw new Error(`OTS preimage does not hash to the on-chain tip ${expectedTip}. You are out of sync with the chain.`);
    }

    // --- reproduce the contract's digest exactly ---
    const coder = ethers.AbiCoder.defaultAbiCoder();
    const actionDigest = ethers.keccak256(
        coder.encode(
            ["bytes32", "uint256", "uint32", "uint256", "address", "bytes32"],
            [await dao.MILESTONE_TYPEHASH(), projectId, await dao.getProjectMilestonesCompleted(projectId),
             amount, await dao.getProjectPayoutRecipient(projectId), attestationHash(attestation)]
        )
    );
    const payload = ethers.keccak256(
        coder.encode(
            ["uint256", "address", "bytes32", "bytes32", "bytes32", "bytes32"],
            [42161n, daoAddr, actionDigest, onChainKeyHash, ethers.keccak256(pqcSignature), otsPreimage]
        )
    );
    const digest = ethers.hashMessage(ethers.getBytes(payload)); // EIP-191 personal_sign

    console.log(`DAO             : ${daoAddr}`);
    console.log(`Project         : ${projectId}  milestone ${await dao.getProjectMilestonesCompleted(projectId)} of ${await dao.getProjectMilestoneCount(projectId)}`);
    console.log(`Recipient       : ${await dao.getProjectPayoutRecipient(projectId)}  (fixed by the DAO vote)`);
    console.log(`Amount          : ${ethers.formatUnits(amount, 18)} OBS`);
    console.log(`Per-tranche cap : ${ethers.formatUnits(await dao.getProjectPerMilestoneCap(projectId), 18)} OBS`);
    console.log(`\nDigest for the MCU to sign (secp256k1, EIP-191):\n  ${digest}\n`);

    if (process.env.DRY_RUN === "1") {
        console.log("DRY_RUN=1 - stopping here. Have the MCU sign the digest above under biometric");
        console.log("consent, then re-run with MCU_ECDSA_SIGNATURE=0x<65-byte signature>.");
        return;
    }

    const ecdsaSignature = process.env.MCU_ECDSA_SIGNATURE;
    if (!ecdsaSignature || !/^0x[0-9a-fA-F]{130}$/.test(ecdsaSignature)) {
        throw new Error("Set MCU_ECDSA_SIGNATURE to the MCU's 65-byte signature over the digest above (or use DRY_RUN=1).");
    }
    const recovered = ethers.recoverAddress(digest, ecdsaSignature);
    const expectedSigner = await dao.getRobotMcuEcdsaSigner();
    if (recovered.toLowerCase() !== expectedSigner.toLowerCase()) {
        throw new Error(`Signature recovers to ${recovered}, but the on-chain MCU signer is ${expectedSigner}.`);
    }
    console.log(`Signature verifies locally against the on-chain MCU signer ${expectedSigner}.\n`);

    if ((await ask("Submit the release transaction? [y/N] ")).toLowerCase() !== "y") return;

    const signed = await connectAsOrchestrator("Authorize milestone release");
    const tx = await signed.robotAuthorizeAndReleaseMilestone(
        projectId, amount,
        [attestation.acresSecured, attestation.hivesInstalled, attestation.honeyKgDistributedFree,
         attestation.atmosphericWaterLiters, attestation.solarKwhGenerated, attestation.batteryKwhStored,
         attestation.beeFlourishingIndexDelta, attestation.offGridVerified, attestation.landAcquired,
         attestation.equipmentOperational, attestation.evidenceHash],
        pqcPublicKey, pqcSignature, ecdsaSignature, otsPreimage
    );
    console.log(`Transaction: ${tx.hash}`);
    await tx.wait();
    console.log("Milestone released. The next authorization for this project unlocks in 60 days.");
}

main().then(() => process.exit(0)).catch((e) => { console.error(e.message || e); process.exit(1); });
