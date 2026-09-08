// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BeeHabitatHarness} from "./Harness.sol";
import {BeeHabitatDAO} from "../contracts/BeeHabitatDAO.sol";

/// @notice End-to-end audit: vault-lock invariants, quorum, timeouts, completion, immutability.
contract BeeHabitatDAOFullAuditTest is BeeHabitatHarness {
    /* ============ INVARIANT: nothing leaves the vault before 5B DAI ============ */

    function test_NoObsCanLeaveTheVaultBeforeTheBondingCurveTarget() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        assertFalse(dao.isVaultUnlocked());

        // Proposals may pass, but they cannot be executed into a funded project.
        _issueLp(daoMember, 100 * 1e18);
        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "premature", 25, 100, 1_000 * 1e18, habitatOperator, true, true, true, true, true
        );
        vm.prank(daoMember);
        dao.vote(propId, true);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        vm.expectRevert(BeeHabitatDAO.VaultLocked.selector);
        dao.executeProposal(propId);

        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.VaultLocked.selector);
        dao.robotAuthorizeAndReleaseMilestone(
            1, 1e18, _goodAttestation(), pqcPublicKey, _validPqcSignature(), new bytes(65), otsChain[OTS_LEN - 1]
        );

        // Every OBS is still in the vault.
        assertEq(obs.balanceOf(address(dao)), VAULT_SEED);
        assertEq(dao.totalObsReleased(), 0);
    }

    function test_ContractExposesNoOwnerOrEscapeHatch() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();

        // There is no owner(), no transferOwnership, no pause, no upgrade, no rescue, no
        // arbitrary-recipient withdrawal. The only outbound transfer is the milestone path.
        (bool ok,) = address(dao).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(dao).call(abi.encodeWithSignature("transferOwnership(address)", unauthorizedUser));
        assertFalse(ok);
        (ok,) = address(dao).call(abi.encodeWithSignature("upgradeTo(address)", unauthorizedUser));
        assertFalse(ok);
        (ok,) = address(dao).call(abi.encodeWithSignature("withdrawProjectFunds(uint256,address,uint256)", 1, unauthorizedUser, 1));
        assertFalse(ok);
        (ok,) = address(dao).call(abi.encodeWithSignature("rescueTokens(address,uint256)", OBS_TOKEN, 1));
        assertFalse(ok);

        assertEq(obs.balanceOf(address(dao)), VAULT_SEED);
    }

    /* ============================== QUORUM ================================ */

    function test_QuorumIsActuallyEnforced() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();

        // 10 members x 100 LP = 1000 LP live supply; quorum is 10% = 100 LP.
        for (uint256 i = 0; i < 10; i++) {
            _issueLp(address(uint160(0x1000 + i)), 100 * 1e18);
        }
        _issueLp(daoMember, 100 * 1e18); // proposer, 1100 LP total => quorum 110 LP

        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "quorum test", 25, 100, 1_000 * 1e18, habitatOperator, true, true, true, true, true
        );
        vm.prank(daoMember);
        dao.vote(propId, true); // 100 LP < 110 LP quorum

        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.expectRevert(BeeHabitatDAO.QuorumNotReached.selector);
        dao.executeProposal(propId);
    }

    function test_QuorumMetAllowsExecution() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();

        _issueLp(daoMember, 100 * 1e18);
        _issueLp(daoMember2, 100 * 1e18);

        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "quorum met", 25, 100, 1_000 * 1e18, habitatOperator, true, true, true, true, true
        );
        vm.prank(daoMember);
        dao.vote(propId, true);
        vm.prank(daoMember2);
        dao.vote(propId, true);

        vm.warp(vm.getBlockTimestamp() + 31 days);
        uint256 pid = dao.executeProposal(propId);
        assertEq(pid, 1);
    }

    function test_RejectedProposalCannotExecute() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();

        _issueLp(daoMember, 100 * 1e18);
        _issueLp(daoMember2, 100 * 1e18);

        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "rejected", 25, 100, 1_000 * 1e18, habitatOperator, true, true, true, true, true
        );
        vm.prank(daoMember);
        dao.vote(propId, false);
        vm.prank(daoMember2);
        dao.vote(propId, false);

        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.expectRevert(BeeHabitatDAO.ProposalRejected.selector);
        dao.executeProposal(propId);
    }

    function test_ProposalCannotBeExecutedTwice() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();
        _issueLp(daoMember, 100 * 1e18);

        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "once", 25, 100, 1_000 * 1e18, habitatOperator, true, true, true, true, true
        );
        vm.prank(daoMember);
        dao.vote(propId, true);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        dao.executeProposal(propId);
        vm.expectRevert(BeeHabitatDAO.ProposalAlreadyExecuted.selector);
        dao.executeProposal(propId);
    }

    function test_ExecutionBeforeVotingEndsReverts() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();
        _issueLp(daoMember, 100 * 1e18);

        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "early", 25, 100, 1_000 * 1e18, habitatOperator, true, true, true, true, true
        );
        vm.prank(daoMember);
        dao.vote(propId, true);

        vm.expectRevert(BeeHabitatDAO.VotingNotEnded.selector);
        dao.executeProposal(propId);
    }

    function test_ProjectCannotExceedItsShareOfTheVault() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();
        _issueLp(daoMember, 100 * 1e18);

        uint256 tooMuch = (VAULT_SEED * 2_000) / 10_000 + 1; // one wei over 20%
        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "greedy", 25, 100, tooMuch, habitatOperator, true, true, true, true, true
        );
        vm.prank(daoMember);
        dao.vote(propId, true);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        vm.expectRevert(BeeHabitatDAO.ExceedsMaxProjectShare.selector);
        dao.executeProposal(propId);
    }

    function test_RevertIf_ExecutingIntoAnEmptyVault() public {
        _commissionRobot();
        _unlockVault();
        _issueLp(daoMember, 100 * 1e18);

        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "no vault", 25, 100, 1e18, habitatOperator, true, true, true, true, true
        );
        vm.prank(daoMember);
        dao.vote(propId, true);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        vm.expectRevert(BeeHabitatDAO.ExceedsMaxProjectShare.selector);
        dao.executeProposal(propId);
    }

    /* ==================== FULL LIFECYCLE TO COMPLETION ==================== */

    function test_FullProjectLifecycleThroughEveryMilestone() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();

        uint256 funding = 60_000 * 1e18;
        uint256 projectId = _passProposal(funding);

        uint32 count = dao.getProjectMilestoneCount(projectId);
        uint256 cap = dao.getProjectPerMilestoneCap(projectId);
        assertEq(count, 6);

        uint256 releasedTotal;
        for (uint32 i = 0; i < count; i++) {
            if (i > 0) vm.warp(vm.getBlockTimestamp() + 61 days);
            uint256 remaining = dao.getProjectFundingRemaining(projectId);
            uint256 amount = remaining < cap ? remaining : cap;
            _releaseMilestone(projectId, amount);
            releasedTotal += amount;
        }

        assertEq(releasedTotal, funding);
        assertEq(dao.getProjectFundingRemaining(projectId), 0);
        assertEq(dao.getProjectMilestonesCompleted(projectId), count);
        assertEq(obs.balanceOf(habitatOperator), funding);
        assertEq(dao.totalObsVaultBalance(), VAULT_SEED - funding);
        assertEq(dao.totalReservedForProjects(), 0);

        // Spending took at least 5 x 60 days: no instant drain, no instant price crash.
        assertGe(vm.getBlockTimestamp() - dao.getProjectStartTime(projectId), 5 * 60 days);

        // A seventh authorisation is impossible: the schedule is exhausted.
        vm.warp(vm.getBlockTimestamp() + 61 days);
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory sig = _mcuSign(projectId, 1e18, att, pqcSig, pre, mcuPrivKey);
        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.AllMilestonesCompleted.selector);
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, sig, pre);

        vm.prank(ADMIN);
        dao.completeProject(projectId);
        assertTrue(dao.getProjectCompleted(projectId));

        assertEq(dao.beeFlourishingIndex(), 6 * 10_000);
        assertFalse(dao.optimalBeeFlourishingReached());
    }

    function test_ProjectCannotBeCompletedEarly() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();
        uint256 projectId = _passProposal(60_000 * 1e18);

        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.MilestonesIncomplete.selector);
        dao.completeProject(projectId);

        _releaseMilestone(projectId, 1e18);
        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.MilestonesIncomplete.selector);
        dao.completeProject(projectId);
    }

    function test_OptimalBeeFlourishingIndexIsReachable() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();
        uint256 projectId = _passProposal(60_000 * 1e18);

        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        att.beeFlourishingIndexDelta = 500_000;
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory sig = _mcuSign(projectId, 1e18, att, pqcSig, pre, mcuPrivKey);

        vm.prank(ADMIN);
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, sig, pre);

        assertEq(dao.beeFlourishingIndex(), 500_000);
        assertTrue(dao.optimalBeeFlourishingReached());
    }

    function test_BeeFlourishingIndexIsCappedAtTheOptimum() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();
        uint256 projectId = _passProposal(60_000 * 1e18);

        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        att.beeFlourishingIndexDelta = type(uint128).max;
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory sig = _mcuSign(projectId, 1e18, att, pqcSig, pre, mcuPrivKey);

        vm.prank(ADMIN);
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, sig, pre);
        assertEq(dao.beeFlourishingIndex(), dao.OPTIMAL_BEE_INDEX_CAP());
    }

    /* ============================== TIMEOUT =============================== */

    function test_TimeoutReturnsUnspentFundsToTheVaultRatherThanBurningThem() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();

        uint256 funding = 60_000 * 1e18;
        uint256 projectId = _passProposal(funding);
        _releaseMilestone(projectId, 1_000 * 1e18);

        assertEq(dao.totalReservedForProjects(), funding - 1_000 * 1e18);

        vm.warp(dao.getProjectDeadline(projectId) + 1);
        dao.checkProjectTimeout(projectId);

        assertTrue(dao.getProjectExpired(projectId));
        assertEq(dao.getProjectFundingRemaining(projectId), 0);
        assertEq(dao.totalReservedForProjects(), 0);
        // Unspent OBS is still in the vault and still available to future projects.
        assertEq(dao.totalObsVaultBalance(), VAULT_SEED - 1_000 * 1e18);
        assertEq(dao.availableVaultBalance(), VAULT_SEED - 1_000 * 1e18);
        assertEq(obs.balanceOf(address(dao)), VAULT_SEED - 1_000 * 1e18);
    }

    function test_TimeoutCannotFireEarly() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();
        uint256 projectId = _passProposal(60_000 * 1e18);

        vm.expectRevert(BeeHabitatDAO.ProjectDeadlineNotReached.selector);
        dao.checkProjectTimeout(projectId);
    }

    function test_ExpiredProjectCannotSpendAgain() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();
        uint256 projectId = _passProposal(60_000 * 1e18);

        vm.warp(dao.getProjectDeadline(projectId) + 1);
        dao.checkProjectTimeout(projectId);

        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 pre = otsChain[otsCursor];
        bytes memory sig = _mcuSign(projectId, 1e18, att, pqcSig, pre, mcuPrivKey);

        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.ProjectHasExpired.selector);
        dao.robotAuthorizeAndReleaseMilestone(projectId, 1e18, att, pqcPublicKey, pqcSig, sig, pre);
    }

    /* ================= IMMUTABILITY AFTER REVOCATION ====================== */

    function test_DaoKeepsOperatingAfterConfigurationIsFrozen() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();

        vm.prank(ADMIN);
        dao.revokeAndUpdateImmutability();
        assertFalse(dao.isConfigUpdatable());

        // Configuration is sealed forever, but the mission continues to run under it.
        uint256 projectId = _passProposal(60_000 * 1e18);
        _releaseMilestone(projectId, 1_000 * 1e18);
        assertEq(obs.balanceOf(habitatOperator), 1_000 * 1e18);

        // And the sealed key is still the one enforcing every release.
        assertEq(dao.getRobotPqcPublicKeyHash(), pqcPublicKeyHash);
        assertEq(dao.getRobotMcuEcdsaSigner(), mcuSigner);
    }

    function test_RevokeBeforeCommissioningPermanentlyBricksSpending() public {
        // Documents the ordering requirement: commission the hardware BEFORE revoking.
        BeeHabitatDAO fresh = new BeeHabitatDAO();
        vm.prank(ADMIN);
        fresh.setupRoomieRobotAndLock(pqcPublicKeyHash);
        vm.prank(ADMIN);
        fresh.revokeAndUpdateImmutability();

        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.ConfigurationImmutable.selector);
        fresh.commissionRoomieRobot(pqcPublicKeyHash, mcuSigner, otsChain[OTS_LEN], uint64(OTS_LEN));

        assertFalse(fresh.isRobotCommissioned());
    }

    /* ========================= ACCOUNTING SAFETY ========================== */

    function test_VaultAccountingMatchesTokenBalanceThroughout() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();
        uint256 projectId = _passProposal(60_000 * 1e18);

        assertEq(dao.totalObsVaultBalance(), obs.balanceOf(address(dao)));
        _releaseMilestone(projectId, 5_000 * 1e18);
        assertEq(dao.totalObsVaultBalance(), obs.balanceOf(address(dao)));

        vm.warp(vm.getBlockTimestamp() + 61 days);
        _releaseMilestone(projectId, 5_000 * 1e18);
        assertEq(dao.totalObsVaultBalance(), obs.balanceOf(address(dao)));
        assertEq(dao.totalObsReleased(), 10_000 * 1e18);
    }

    function test_ConcurrentProjectsCannotOverCommitTheVault() public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();

        // Each project may take at most 20% of what is still unreserved.
        uint256 p1 = _passProposal((VAULT_SEED * 2_000) / 10_000);
        assertEq(dao.totalReservedForProjects(), dao.getProjectFundingAmount(p1));

        uint256 available = dao.availableVaultBalance();
        _issueLp(daoMember2, 100 * 1e18);
        vm.prank(daoMember2);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "second", 25, 100, (available * 2_000) / 10_000 + 1, habitatOperator, true, true, true, true, true
        );
        vm.prank(daoMember2);
        dao.vote(propId, true);
        vm.warp(vm.getBlockTimestamp() + 31 days);

        vm.expectRevert(BeeHabitatDAO.ExceedsMaxProjectShare.selector);
        dao.executeProposal(propId);

        assertLe(dao.totalReservedForProjects(), dao.totalObsVaultBalance());
    }

    function testFuzz_VaultIsNeverOverCommitted(uint256 funding) public {
        _commissionRobot();
        _fundVault(VAULT_SEED);
        _unlockVault();

        funding = bound(funding, 1, (VAULT_SEED * 2_000) / 10_000);
        uint256 pid = _passProposal(funding);

        assertEq(dao.getProjectFundingAmount(pid), funding);
        assertLe(dao.totalReservedForProjects(), dao.totalObsVaultBalance());
        assertLe(dao.getProjectPerMilestoneCap(pid), dao.getProjectTrancheCeiling(pid));
        assertGe(
            uint256(dao.getProjectMilestoneCount(pid)) * dao.getProjectPerMilestoneCap(pid),
            funding
        );
    }
}
