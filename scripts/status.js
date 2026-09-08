/**
 * Read-only status of the deployed DAO.
 *
 *   node scripts/status.js
 */
const { ethers, readOnlyDao, ARBITRUM_RPC, ARBITRUM_ONE } = require("./_common");

async function main() {
    const dao = readOnlyDao();
    const target = await dao.BONDING_CURVE_DAI_UNLOCK_TARGET();
    const reserves = await dao.bondingCurveDaiReserves();
    const pct = target > 0n ? (reserves * 10000n) / target : 0n;

    console.log(`DAO                 : ${await dao.getAddress()}`);
    console.log(`OBS token           : ${await dao.OBS_TOKEN()}`);
    console.log(`Orchestrator        : ${await dao.ADMIN_ORCHESTRATOR()}`);
    console.log("");
    console.log(`Curve reserves      : ${ethers.formatUnits(reserves, 18)} / ${ethers.formatUnits(target, 18)} DAI (${Number(pct) / 100}%)`);
    console.log(`Vault unlocked      : ${await dao.isVaultUnlocked()}`);
    console.log(`Vault balance       : ${ethers.formatUnits(await dao.totalObsVaultBalance(), 18)} OBS`);
    console.log(`  reserved          : ${ethers.formatUnits(await dao.totalReservedForProjects(), 18)} OBS`);
    console.log(`  available         : ${ethers.formatUnits(await dao.availableVaultBalance(), 18)} OBS`);
    console.log(`  released to date  : ${ethers.formatUnits(await dao.totalObsReleased(), 18)} OBS`);
    console.log("");
    console.log(`Robot provisioned   : ${await dao.isRobotConfigured()}`);
    console.log(`MCU commissioned    : ${await dao.isRobotCommissioned()}`);
    console.log(`Config updatable    : ${await dao.isConfigUpdatable()}`);
    console.log(`PQC key hash        : ${await dao.getRobotPqcPublicKeyHash()}`);
    console.log(`MCU ECDSA signer    : ${await dao.getRobotMcuEcdsaSigner()}`);
    console.log(`OTS links remaining : ${await dao.getRobotOtsRemaining()}`);
    console.log("");
    console.log(`Proposals           : ${await dao.getProposalCount()}`);
    console.log(`Projects            : ${await dao.getProjectCount()}`);
    console.log(`Bee flourishing     : ${await dao.beeFlourishingIndex()} / ${await dao.TARGET_BEE_FLOURISHING_INDEX()}` +
                `${(await dao.optimalBeeFlourishingReached()) ? "  OPTIMUM REACHED" : ""}`);

    const projectCount = await dao.getProjectCount();
    for (let i = 1n; i <= projectCount; i++) {
        console.log(`\nProject ${i}`);
        console.log(`  recipient   : ${await dao.getProjectPayoutRecipient(i)}`);
        console.log(`  funding     : ${ethers.formatUnits(await dao.getProjectFundingAmount(i), 18)} OBS` +
                    ` (${ethers.formatUnits(await dao.getProjectFundingRemaining(i), 18)} remaining)`);
        console.log(`  milestones  : ${await dao.getProjectMilestonesCompleted(i)} / ${await dao.getProjectMilestoneCount(i)}`);
        console.log(`  next unlock : ${new Date(Number(await dao.nextMilestoneUnlockTime(i)) * 1000).toISOString()}`);
        console.log(`  deadline    : ${new Date(Number(await dao.getProjectDeadline(i)) * 1000).toISOString()}`);
        console.log(`  completed   : ${await dao.getProjectCompleted(i)}   expired: ${await dao.getProjectExpired(i)}`);
    }
}

main().then(() => process.exit(0)).catch((e) => { console.error(e.message || e); process.exit(1); });
