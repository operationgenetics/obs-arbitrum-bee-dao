/**
 * FINAL, IRREVERSIBLE. Freezes the robot configuration forever.
 *
 *   node scripts/revoke-immutability.js
 *
 * After this transaction the PQC public key, the MCU signer and the OTS chain can never be
 * changed again by anyone, including the orchestrator. Run it only after the real robot MCU has
 * been commissioned and verified - a revoke before commissioning permanently bricks spending.
 */
const { ask, readOnlyDao, connectAsOrchestrator } = require("./_common");

async function main() {
    const dao = readOnlyDao();

    if (!(await dao.isConfigUpdatable())) {
        console.log("Configuration is already permanently immutable. Nothing to do.");
        return;
    }

    const commissioned = await dao.isRobotCommissioned();
    console.log(`DAO                 : ${await dao.getAddress()}`);
    console.log(`Robot provisioned   : ${await dao.isRobotConfigured()}`);
    console.log(`MCU commissioned    : ${commissioned}`);
    console.log(`PQC key hash        : ${await dao.getRobotPqcPublicKeyHash()}`);
    console.log(`MCU ECDSA signer    : ${await dao.getRobotMcuEcdsaSigner()}`);
    console.log(`OTS chain tip       : ${await dao.getRobotOtsChainTip()}`);
    console.log(`OTS links remaining : ${await dao.getRobotOtsRemaining()}`);

    if (!commissioned) {
        console.log("\nREFUSING: the MCU is not commissioned. Revoking now would permanently");
        console.log("brick every fund release. Run scripts/commission-robot.js first.");
        process.exitCode = 1;
        return;
    }

    console.log("\nThis is irreversible. The configuration above becomes permanent forever.");
    if ((await ask('Type exactly "FREEZE FOREVER" to continue: ')) !== "FREEZE FOREVER") {
        console.log("Aborted.");
        return;
    }

    const dao2 = await connectAsOrchestrator("Freeze configuration forever");
    const tx = await dao2.revokeAndUpdateImmutability();
    console.log(`Transaction: ${tx.hash}`);
    await tx.wait();
    console.log("Configuration is now permanently immutable.");
}

main().then(() => process.exit(0)).catch((e) => { console.error(e.message || e); process.exit(1); });
