/**
 * Provisional Roomie robot anchoring - run immediately after deployment.
 *
 *   node scripts/setup-robot.js
 *
 * Anchors the robot slot with a deterministic placeholder commitment. This does NOT enable
 * spending: funds stay locked until `commission-robot.js` binds the real MCU credential.
 */
const { ethers, ask, daoAddress, readOnlyDao, connectAsOrchestrator } = require("./_common");

async function main() {
    const address = daoAddress();
    const dao = readOnlyDao();

    if (await dao.isRobotConfigured()) {
        console.log(`Robot slot already provisioned: ${await dao.getRobotPqcPublicKeyHash()}`);
        return;
    }
    if (!(await dao.isConfigUpdatable())) {
        throw new Error("Configuration is permanently immutable. Nothing can be provisioned.");
    }

    const provisional = ethers.keccak256(
        ethers.toUtf8Bytes(`BeeHabitatDAO:ROOMIE_PROVISIONAL:${address.toLowerCase()}`)
    );
    console.log(`DAO         : ${address}`);
    console.log(`Provisional : ${provisional}`);
    console.log("This is a placeholder. Spending stays impossible until the MCU is commissioned.\n");

    if ((await ask("Send setupRoomieRobotAndLock now? [y/N] ")).toLowerCase() !== "y") return;

    const signed = await connectAsOrchestrator("Provision Roomie robot slot");
    const tx = await signed.setupRoomieRobotAndLock(provisional);
    console.log(`Transaction: ${tx.hash}`);
    await tx.wait();
    console.log("Roomie robot slot provisioned.");
}

main().then(() => process.exit(0)).catch((e) => { console.error(e.message || e); process.exit(1); });
