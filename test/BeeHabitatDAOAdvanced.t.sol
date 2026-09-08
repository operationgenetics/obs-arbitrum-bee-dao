// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BeeHabitatHarness} from "./Harness.sol";
import {BeeHabitatDAO} from "../contracts/BeeHabitatDAO.sol";

/// @notice Hybrid post-quantum authorisation and the time-locked, mission-bound fund release path.
contract BeeHabitatDAOAdvancedTest is BeeHabitatHarness {
    uint256 internal projectId;
    uint256 internal constant FUNDING = 60_000 * 1e18; // 6% of the seeded vault

    function setUp() public override {
        super.setUp();
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();
        projectId = _passProposal(FUNDING);
    }

    /* -------------------- mathematical time-lock schedule ---------------- */

    function test_ProjectIsStretchedOverAMathematicalSchedule() public view {
        uint32 count = dao.getProjectMilestoneCount(projectId);
        uint256 cap = dao.getProjectPerMilestoneCap(projectId);
        uint256 ceiling = dao.getProjectTrancheCeiling(projectId);

        assertGe(count, dao.MIN_PROJECT_MILESTONES());
        assertEq(ceiling, (VAULT_SEED * 250) / 10_000); // 2.5% anti-dump ceiling
        assertLe(cap, ceiling);
        assertGe(uint256(count) * cap, FUNDING); // the schedule can actually deliver the funding

        // Deadline spans the entire schedule: 60 days per tranche plus grace.
        assertEq(
            dao.getProjectDeadline(projectId),
            dao.getProjectStartTime(projectId) + uint256(count) * 60 days + 90 days
        );
    }

    function test_FundingIsWhatTheDaoVotedOnNotWhatTheExecutorChooses() public view {
        // executeProposal takes no amount argument; funding comes from the voted proposal.
        assertEq(dao.getProjectFundingAmount(projectId), FUNDING);
        assertEq(dao.getProjectFundingRemaining(projectId), FUNDING);
        assertEq(dao.getProjectPayoutRecipient(projectId), habitatOperator);
        assertEq(dao.totalReservedForProjects(), FUNDING);
        assertEq(dao.availableVaultBalance(), VAULT_SEED - FUNDING);
    }

    /* ------------------------ happy path release ------------------------- */

    function test_RobotAuthorizedMilestoneReleasesToTheVotedRecipient() public {
        uint256 amount = dao.getProjectPerMilestoneCap(projectId);
        uint256 before = obs.balanceOf(habitatOperator);

        _releaseMilestone(projectId, amount);

        assertEq(obs.balanceOf(habitatOperator) - before, amount);
        assertEq(dao.getProjectMilestonesCompleted(projectId), 1);
        assertEq(dao.getProjectFundingRemaining(projectId), FUNDING - amount);
        assertEq(dao.totalObsVaultBalance(), VAULT_SEED - amount);
        assertEq(dao.totalObsReleased(), amount);
        assertEq(dao.getRobotOtsRemaining(), uint64(OTS_LEN - 1));
    }

    function test_MissionLedgerAccumulatesRealWorldDelivery() public {
        _releaseMilestone(projectId, 1e18);
        BeeHabitatDAO.MissionLedger memory l = dao.getMissionLedger(projectId);
        assertEq(l.acresSecured, 25);
        assertEq(l.hivesInstalled, 40);
        assertEq(l.honeyKgDistributedFree, 120);
        assertEq(l.atmosphericWaterLiters, 9_000);
        assertEq(l.solarKwhGenerated, 4_200);
        assertEq(l.batteryKwhStored, 800);
        assertEq(dao.beeFlourishingIndex(), 10_000);
    }

    /* ---------------- bi-monthly gating: 1x every 2 months ---------------- */

    function test_MilestoneGatedToOncePerTwoMonths() public {
        _releaseMilestone(projectId, 1e18);

        vm.warp(block.timestamp + 59 days);
        _expectMilestoneRevert(1e18, "Milestone locked: Bi-monthly cycle (1 time every 2 months) not reached");

        vm.warp(block.timestamp + 1 days + 1);
        _releaseMilestone(projectId, 1e18);
        assertEq(dao.getProjectMilestonesCompleted(projectId), 2);
    }

    function test_NextMilestoneUnlockTimeIsExposed() public {
        assertEq(dao.nextMilestoneUnlockTime(projectId), dao.getProjectStartTime(projectId));
        _releaseMilestone(projectId, 1e18);
        assertEq(dao.nextMilestoneUnlockTime(projectId), block.timestamp + 60 days);
    }

    /* --------------------- hybrid PQC: negative cases -------------------- */

    function test_RevertIf_PqcPublicKeyDoesNotMatchCommitment() public {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory ecdsaSig = _mcuSign(projectId, 1e18, att, pqcSig, pre, mcuPrivKey);

        bytes memory wrongKey = new bytes(1312);
        wrongKey[0] = 0xFF;

        vm.prank(ADMIN);
        vm.expectRevert("PQC public key mismatch");
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, wrongKey, pqcSig, ecdsaSig, pre);
    }

    function test_RevertIf_OtsPreimageIsWrong() public {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 badPre = keccak256("not-a-chain-link");
        bytes memory ecdsaSig = _mcuSign(projectId, 1e18, att, pqcSig, badPre, mcuPrivKey);

        vm.prank(ADMIN);
        vm.expectRevert("Invalid PQC OTS preimage");
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, ecdsaSig, badPre);
    }

    function test_RevertIf_OtsPreimageIsReplayed() public {
        bytes32 used = otsChain[otsCursor];
        _releaseMilestone(projectId, 1e18);
        vm.warp(block.timestamp + 61 days);

        // Replaying the consumed link no longer hashes to the advanced tip.
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes memory ecdsaSig = _mcuSign(projectId, 1e18, att, pqcSig, used, mcuPrivKey);

        vm.prank(ADMIN);
        vm.expectRevert("Invalid PQC OTS preimage");
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, ecdsaSig, used);
    }

    function test_RevertIf_PqcSignatureIsClassicallySized() public {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory shortSig = new bytes(511); // one byte below the PQC floor
        bytes32 pre = otsChain[otsCursor];
        bytes memory ecdsaSig = _mcuSign(projectId, 1e18, att, shortSig, pre, mcuPrivKey);

        vm.prank(ADMIN);
        vm.expectRevert("PQC signature too short");
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, shortSig, ecdsaSig, pre);
    }

    function test_RevertIf_EcdsaLegSignedByTheWrongKey() public {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory forged = _mcuSign(projectId, 1e18, att, pqcSig, pre, 0xDEADBEEF);

        vm.prank(ADMIN);
        vm.expectRevert("Invalid MCU ECDSA signature");
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, forged, pre);
    }

    function test_RevertIf_EcdsaSignatureIsMalformed() public {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];

        vm.prank(ADMIN);
        vm.expectRevert("Invalid ECDSA signature length");
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, hex"1234", pre);
    }

    function test_RevertIf_AmountIsTamperedAfterSigning() public {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory ecdsaSig = _mcuSign(projectId, 1e18, att, pqcSig, pre, mcuPrivKey);

        // The MCU authorised 1 OBS; the orchestrator tries to push 2.
        vm.prank(ADMIN);
        vm.expectRevert("Invalid MCU ECDSA signature");
        dao.robotAuthorizeAndReleaseMilestone(projectId, 2e18, att, pqcPublicKey, pqcSig, ecdsaSig, pre);
    }

    function test_RevertIf_AttestationIsTamperedAfterSigning() public {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory ecdsaSig = _mcuSign(projectId, 1e18, att, pqcSig, pre, mcuPrivKey);

        att.honeyKgDistributedFree = 999_999; // inflate the claim after the robot signed
        vm.prank(ADMIN);
        vm.expectRevert("Invalid MCU ECDSA signature");
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, ecdsaSig, pre);
    }

    function test_RevertIf_RobotNotCommissioned() public {
        // Provisional setup only - no MCU hardware bound yet, so nothing can be spent.
        BeeHabitatDAO fresh = new BeeHabitatDAO();
        vm.prank(ADMIN);
        fresh.setupRoomieRobotAndLock(pqcPublicKeyHash);
        assertFalse(fresh.isRobotCommissioned());

        obs.mint(funder, VAULT_SEED);
        vm.startPrank(funder);
        obs.approve(address(fresh), VAULT_SEED);
        fresh.depositToVault(VAULT_SEED);
        vm.stopPrank();
        obs.setDaiReserve(fresh.BONDING_CURVE_DAI_UNLOCK_TARGET());
        fresh.checkAndUnlockVault();

        uint256 pid = _passProposalOn(fresh, 60_000 * 1e18);

        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[OTS_LEN - 1];
        bytes memory sig = _mcuSignOn(fresh, pid, 1e18, att, pqcSig, pre, mcuPrivKey);

        vm.prank(ADMIN);
        vm.expectRevert("Roomie robot MCU not commissioned");
        fresh.robotAuthorizeAndReleaseMilestone(pid, 1e18, att, pqcPublicKey, pqcSig, sig, pre);
    }

    function test_OtsChainExhaustionStopsSpending() public {
        // Commission a one-shot chain, then prove the second authorisation is impossible.
        BeeHabitatDAO fresh = _freshFundedDao(1);
        uint256 pid = _passProposalOn(fresh, 60_000 * 1e18);

        _releaseOn(fresh, pid, 1e18, otsChain[OTS_LEN - 1]);
        assertEq(fresh.getRobotOtsRemaining(), 0);

        vm.warp(block.timestamp + 61 days);
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[OTS_LEN - 2];
        bytes memory sig = _mcuSignOn(fresh, pid, 1e18, att, pqcSig, pre, mcuPrivKey);

        vm.prank(ADMIN);
        vm.expectRevert("PQC OTS chain exhausted");
        fresh.robotAuthorizeAndReleaseMilestone(pid, 1e18, att, pqcPublicKey, pqcSig, sig, pre);
    }

    /* ------------------ hardcoded mission rules at spend ------------------ */

    function test_EveryMissionRuleIsReEnforcedAtEveryRelease() public {
        _assertRuleBlocks(_mutate(0), "Mission rule: site must be fully off-grid");
        _assertRuleBlocks(_mutate(1), "Mission rule: solar generation required");
        _assertRuleBlocks(_mutate(2), "Mission rule: battery storage required");
        _assertRuleBlocks(_mutate(3), "Mission rule: atmospheric water generation required");
        _assertRuleBlocks(_mutate(4), "Mission rule: free honey distribution required");
        _assertRuleBlocks(_mutate(5), "Mission rule: indoor bee habitat hives required");
        _assertRuleBlocks(_mutate(6), "Mission rule: land must be acquired/held");
        _assertRuleBlocks(_mutate(7), "Mission rule: maintenance equipment must be operational");
        _assertRuleBlocks(_mutate(8), "Mission rule: robot evidence bundle required");
    }

    /* --------------------------- anti-dump caps -------------------------- */

    function test_RevertIf_TrancheExceedsPerMilestoneCap() public {
        uint256 cap = dao.getProjectPerMilestoneCap(projectId);
        _expectMilestoneRevert(cap + 1, "Exceeds per-milestone cap");
    }

    function test_FullFundingCannotBeDrainedInOneTransaction() public {
        _expectMilestoneRevert(FUNDING, "Exceeds per-milestone cap");
    }

    /* ---------------------- authorisation surface ------------------------ */

    function test_RevertIf_NonAdminTriesToRelease() public {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory sig = _mcuSign(projectId, 1e18, att, pqcSig, pre, mcuPrivKey);

        vm.prank(unauthorizedUser);
        vm.expectRevert("Unauthorized: Must match hardware orchestrator");
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, sig, pre);
    }

    /* ------------------------------ helpers ------------------------------ */

    function _expectMilestoneRevert(uint256 amount, string memory reason) internal {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory sig = _mcuSign(projectId, amount, att, pqcSig, pre, mcuPrivKey);

        vm.prank(ADMIN);
        vm.expectRevert(bytes(reason));
        dao.robotAuthorizeAndReleaseMilestone(projectId, amount, att, pqcPublicKey, pqcSig, sig, pre);
    }

    function _mutate(uint256 which) internal pure returns (BeeHabitatDAO.MilestoneAttestation memory a) {
        a = _goodAttestation();
        if (which == 0) a.offGridVerified = false;
        else if (which == 1) a.solarKwhGenerated = 0;
        else if (which == 2) a.batteryKwhStored = 0;
        else if (which == 3) a.atmosphericWaterLiters = 0;
        else if (which == 4) a.honeyKgDistributedFree = 0;
        else if (which == 5) a.hivesInstalled = 0;
        else if (which == 6) a.landAcquired = false;
        else if (which == 7) a.equipmentOperational = false;
        else a.evidenceHash = bytes32(0);
    }

    function _assertRuleBlocks(BeeHabitatDAO.MilestoneAttestation memory att, string memory reason) internal {
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory sig = _mcuSign(projectId, 1e18, att, pqcSig, pre, mcuPrivKey);

        vm.prank(ADMIN);
        vm.expectRevert(bytes(reason));
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, sig, pre);
    }

    function _freshFundedDao(uint64 otsLength) internal returns (BeeHabitatDAO fresh) {
        fresh = new BeeHabitatDAO();
        vm.prank(ADMIN);
        fresh.commissionRoomieRobot(pqcPublicKeyHash, mcuSigner, otsChain[OTS_LEN], otsLength);

        obs.mint(funder, VAULT_SEED);
        vm.startPrank(funder);
        obs.approve(address(fresh), VAULT_SEED);
        fresh.depositToVault(VAULT_SEED);
        vm.stopPrank();

        obs.setDaiReserve(fresh.BONDING_CURVE_DAI_UNLOCK_TARGET());
        fresh.checkAndUnlockVault();
    }

    function _passProposalOn(BeeHabitatDAO d, uint256 funding) internal returns (uint256) {
        vm.prank(ADMIN);
        d.issueMonthlyLpTokens(daoMember2, 100 * 1e18);
        vm.prank(daoMember2);
        uint256 propId = d.createOffGridBeeHabitatProposal(
            "off-grid apiary", 25, 250_000, funding, habitatOperator, true, true, true, true, true
        );
        vm.prank(daoMember2);
        d.vote(propId, true);
        vm.warp(block.timestamp + 31 days);
        return d.executeProposal(propId);
    }

    function _mcuSignOn(
        BeeHabitatDAO d,
        uint256 pid,
        uint256 amount,
        BeeHabitatDAO.MilestoneAttestation memory att,
        bytes memory pqcSig,
        bytes32 pre,
        uint256 key
    ) internal view returns (bytes memory) {
        bytes32 actionDigest = keccak256(
            abi.encode(
                d.MILESTONE_TYPEHASH(),
                pid,
                d.getProjectMilestonesCompleted(pid),
                amount,
                d.getProjectPayoutRecipient(pid),
                _attestationHash(att)
            )
        );
        bytes32 payload = keccak256(
            abi.encode(block.chainid, address(d), actionDigest, d.getRobotPqcPublicKeyHash(), keccak256(pqcSig), pre)
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload)));
        return abi.encodePacked(r, s, v);
    }

    function _releaseOn(BeeHabitatDAO d, uint256 pid, uint256 amount, bytes32 pre) internal {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes memory sig = _mcuSignOn(d, pid, amount, att, pqcSig, pre, mcuPrivKey);
        vm.prank(ADMIN);
        d.robotAuthorizeAndReleaseMilestone(pid, amount, att, pqcPublicKey, pqcSig, sig, pre);
    }
}
