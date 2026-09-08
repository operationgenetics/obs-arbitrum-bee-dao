// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BeeHabitatHarness, MockObsToken, SilentObsToken} from "./Harness.sol";
import {BeeHabitatDAO} from "../contracts/BeeHabitatDAO.sol";

/// @notice Core suite: wiring, robot lifecycle, LP economics, proposals, voting, vault.
contract BeeHabitatDAOTest is BeeHabitatHarness {
    /* ------------------------------ wiring ------------------------------ */

    function test_ObsTokenIsTheRealObscuraOnArbitrumOne() public view {
        assertEq(dao.OBS_TOKEN(), 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0);
        assertEq(dao.obsToken(), 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0);
    }

    function test_AdminOrchestratorAddressCorrect() public view {
        assertEq(dao.ADMIN_ORCHESTRATOR(), 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e);
    }

    function test_ConstantsAndInitialState() public view {
        assertEq(dao.BONDING_CURVE_DAI_UNLOCK_TARGET(), 5_000_000_000 * 1e18);
        assertEq(dao.MONTHLY_LP_ISSUANCE(), 100 * 1e18);
        assertEq(dao.PROPOSAL_THRESHOLD(), 50 * 1e18);
        assertEq(dao.VOTING_PERIOD_DURATION(), 30 days);
        assertEq(dao.LP_EPOCH(), 30 days);
        assertEq(dao.MILESTONE_GATING_INTERVAL(), 60 days);
        assertEq(dao.QUORUM_PERCENTAGE(), 10);
        assertEq(dao.MIN_FLOWERING_ACRES_TARGET(), 20);
        assertEq(dao.OPTIMAL_BEE_INDEX_CAP(), 500_000);
        assertEq(dao.TARGET_BEE_FLOURISHING_INDEX(), 500_000);
        assertEq(dao.MIN_PROJECT_MILESTONES(), 6);
        assertEq(dao.MAX_PROJECT_BPS_OF_VAULT(), 2_000);
        assertEq(dao.MAX_TRANCHE_BPS_OF_VAULT(), 250);

        assertFalse(dao.isRobotConfigured());
        assertFalse(dao.isRobotCommissioned());
        assertTrue(dao.isConfigUpdatable());
        assertFalse(dao.isVaultUnlocked());
        assertEq(dao.totalObsVaultBalance(), 0);
        assertEq(dao.beeFlourishingIndex(), 0);
    }

    function test_ZeroConfigDeployment() public {
        // No constructor arguments, no initializer, no owner to set: deploy and sign, nothing else.
        BeeHabitatDAO fresh = new BeeHabitatDAO();
        assertEq(fresh.OBS_TOKEN(), OBS_TOKEN);
        assertEq(fresh.ADMIN_ORCHESTRATOR(), ADMIN);
        assertTrue(fresh.isConfigUpdatable());
    }

    /* ------------------------- robot lifecycle -------------------------- */

    function test_RobotSetupImmediatelyAfterDeployment() public {
        BeeHabitatDAO fresh = new BeeHabitatDAO();
        vm.prank(ADMIN);
        fresh.setupRoomieRobotAndLock(pqcPublicKeyHash);
        assertTrue(fresh.isRobotConfigured());
        assertEq(fresh.getRobotPqcPublicKeyHash(), pqcPublicKeyHash);
        // Provisional only: spending is impossible until the real MCU is commissioned.
        assertFalse(fresh.isRobotCommissioned());
    }

    function test_RevertIf_UnauthorizedRobotSetup() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert(BeeHabitatDAO.Unauthorized.selector);
        dao.setupRoomieRobotAndLock(pqcPublicKeyHash);

        vm.prank(unauthorizedUser);
        vm.expectRevert(BeeHabitatDAO.Unauthorized.selector);
        dao.commissionRoomieRobot(pqcPublicKeyHash, mcuSigner, otsChain[OTS_LEN], uint64(OTS_LEN));

        vm.prank(unauthorizedUser);
        vm.expectRevert(BeeHabitatDAO.Unauthorized.selector);
        dao.revokeAndUpdateImmutability();
    }

    function test_CommissionRobotWhenHardwareArrives() public {
        vm.prank(ADMIN);
        dao.setupRoomieRobotAndLock(keccak256("placeholder-until-hardware-lands"));
        assertFalse(dao.isRobotCommissioned());

        _commissionRobot();

        assertTrue(dao.isRobotCommissioned());
        assertEq(dao.getRobotPqcPublicKeyHash(), pqcPublicKeyHash);
        assertEq(dao.getRobotMcuEcdsaSigner(), mcuSigner);
        assertEq(dao.getRobotOtsChainTip(), otsChain[OTS_LEN]);
        assertEq(dao.getRobotOtsRemaining(), uint64(OTS_LEN));
    }

    function test_RevertIf_CommissionWithZeroValues() public {
        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.InvalidPqcPublicKeyHash.selector);
        dao.commissionRoomieRobot(bytes32(0), mcuSigner, otsChain[OTS_LEN], 1);

        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.InvalidMcuSigner.selector);
        dao.commissionRoomieRobot(pqcPublicKeyHash, address(0), otsChain[OTS_LEN], 1);

        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.InvalidOtsChainTip.selector);
        dao.commissionRoomieRobot(pqcPublicKeyHash, mcuSigner, bytes32(0), 1);

        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.InvalidOtsChainLength.selector);
        dao.commissionRoomieRobot(pqcPublicKeyHash, mcuSigner, otsChain[OTS_LEN], 0);
    }

    function test_RevokeMakesConfigurationPermanentlyImmutable() public {
        vm.prank(ADMIN);
        dao.setupRoomieRobotAndLock(pqcPublicKeyHash);
        vm.prank(ADMIN);
        dao.updateRobotPqcPublicKey(keccak256("rotated"));
        assertEq(dao.getRobotPqcPublicKeyHash(), keccak256("rotated"));

        _commissionRobot();

        vm.prank(ADMIN);
        dao.revokeAndUpdateImmutability();
        assertFalse(dao.isConfigUpdatable());

        // Every configuration path is now permanently sealed - for the admin and for everyone.
        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.ConfigurationImmutable.selector);
        dao.setupRoomieRobotAndLock(keccak256("x"));

        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.ConfigurationImmutable.selector);
        dao.updateRobotPqcPublicKey(keccak256("x"));

        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.ConfigurationImmutable.selector);
        dao.commissionRoomieRobot(keccak256("x"), unauthorizedUser, keccak256("y"), 10);

        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.ConfigurationImmutable.selector);
        dao.revokeAndUpdateImmutability();
    }

    function test_RevertIf_UpdateKeyBeforeProvisioning() public {
        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.RobotNotProvisioned.selector);
        dao.updateRobotPqcPublicKey(keccak256("x"));
    }

    /* ------------------------------- LP --------------------------------- */

    function test_MonthlyLpIssuanceCappedAt100PerMember() public {
        _issueLp(daoMember, 60 * 1e18);
        assertEq(dao.getVotingPower(daoMember), 60 * 1e18);

        _issueLp(daoMember, 40 * 1e18);
        assertEq(dao.getVotingPower(daoMember), 100 * 1e18);

        // The 100 LP/month ceiling is cumulative, not per call.
        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.ExceedsMonthlyIssuanceLimit.selector);
        dao.issueMonthlyLpTokens(daoMember, 1);
    }

    function test_RevertIf_SingleIssuanceExceedsMonthlyCap() public {
        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.ExceedsMonthlyIssuanceLimit.selector);
        dao.issueMonthlyLpTokens(daoMember, 101 * 1e18);
    }

    function test_RevertIf_UnauthorizedIssuesLp() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert(BeeHabitatDAO.Unauthorized.selector);
        dao.issueMonthlyLpTokens(daoMember, 1e18);
    }

    function test_LpExpiresAtMonthBoundaryAndDoesNotRollOver() public {
        _issueLp(daoMember, 100 * 1e18);
        assertEq(dao.getVotingPower(daoMember), 100 * 1e18);

        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertEq(dao.getVotingPower(daoMember), 0);

        // A fresh month grants a fresh 100 - the expired LP is gone, never carried forward.
        _issueLp(daoMember, 100 * 1e18);
        assertEq(dao.getVotingPower(daoMember), 100 * 1e18);
    }

    function test_ActiveLpSupplyTracksTheLiveEpochOnly() public {
        _issueLp(daoMember, 100 * 1e18);
        _issueLp(daoMember2, 100 * 1e18);
        assertEq(dao.getTotalActiveLpSupply(), 200 * 1e18);

        vm.warp(vm.getBlockTimestamp() + 31 days);
        assertEq(dao.getTotalActiveLpSupply(), 0);
    }

    function test_MultipleMembersLpTracking() public {
        _issueLp(daoMember, 100 * 1e18);
        _issueLp(daoMember2, 75 * 1e18);
        assertEq(dao.getVotingPower(daoMember), 100 * 1e18);
        assertEq(dao.getVotingPower(daoMember2), 75 * 1e18);

        vm.warp(vm.getBlockTimestamp() + 31 days);
        assertEq(dao.getVotingPower(daoMember), 0);
        assertEq(dao.getVotingPower(daoMember2), 0);
    }

    /* ---------------------------- proposals ----------------------------- */

    function test_ProposalRequires50LpThreshold() public {
        _issueLp(daoMember, 49 * 1e18);
        vm.prank(daoMember);
        vm.expectRevert(BeeHabitatDAO.InsufficientLpToPropose.selector);
        dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, habitatOperator, true, true, true, true, true);

        _issueLp(daoMember, 1e18); // now exactly 50
        vm.prank(daoMember);
        uint256 id = dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, habitatOperator, true, true, true, true, true);
        assertEq(id, 1);
    }

    function test_ExpiredLpCannotPropose() public {
        _issueLp(daoMember, 100 * 1e18);
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(daoMember);
        vm.expectRevert(BeeHabitatDAO.InsufficientLpToPropose.selector);
        dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, habitatOperator, true, true, true, true, true);
    }

    function test_ProposalRequiresEveryHardcodedMissionRule() public {
        _issueLp(daoMember, 100 * 1e18);
        vm.startPrank(daoMember);

        vm.expectRevert(BeeHabitatDAO.BelowMinimumAcreage.selector);
        dao.createOffGridBeeHabitatProposal("x", 19, 100, 1e18, habitatOperator, true, true, true, true, true);

        vm.expectRevert(BeeHabitatDAO.ExceedsBeeIndexCap.selector);
        dao.createOffGridBeeHabitatProposal("x", 25, 500_001, 1e18, habitatOperator, true, true, true, true, true);

        vm.expectRevert(BeeHabitatDAO.SolarAndBatteryRequired.selector);
        dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, habitatOperator, false, true, true, true, true);

        vm.expectRevert(BeeHabitatDAO.AtmosphericWaterRequired.selector);
        dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, habitatOperator, true, false, true, true, true);

        vm.expectRevert(BeeHabitatDAO.LandAcquisitionRequired.selector);
        dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, habitatOperator, true, true, false, true, true);

        vm.expectRevert(BeeHabitatDAO.EquipmentAcquisitionRequired.selector);
        dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, habitatOperator, true, true, true, false, true);

        vm.expectRevert(BeeHabitatDAO.HoneyDistributionRequired.selector);
        dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, habitatOperator, true, true, true, true, false);

        vm.expectRevert(BeeHabitatDAO.FundingRequired.selector);
        dao.createOffGridBeeHabitatProposal("x", 25, 100, 0, habitatOperator, true, true, true, true, true);

        vm.expectRevert(BeeHabitatDAO.InvalidRecipient.selector);
        dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, address(0), true, true, true, true, true);

        vm.stopPrank();
    }

    function test_ValidProposalStoresEverything() public {
        _issueLp(daoMember, 100 * 1e18);
        vm.prank(daoMember);
        uint256 id = dao.createOffGridBeeHabitatProposal(
            "Indoor off-grid apiary", 40, 300_000, 500 * 1e18, habitatOperator, true, true, true, true, true
        );

        assertEq(dao.getProposalId(id), 1);
        assertEq(dao.getProposalProposer(id), daoMember);
        assertEq(dao.getProposalPayoutRecipient(id), habitatOperator);
        assertEq(dao.getProposalTargetAcres(id), 40);
        assertEq(dao.getProposalBeeIndex(id), 300_000);
        assertEq(dao.getProposalRequestedFunding(id), 500 * 1e18);
        assertTrue(dao.getProposalSolarAndBattery(id));
        assertTrue(dao.getProposalAwg(id));
        assertTrue(dao.getProposalLandAcquisition(id));
        assertTrue(dao.getProposalEquipmentAcquisition(id));
        assertTrue(dao.getProposalHoneyProduction(id));
        assertEq(dao.getProposalEndTime(id), dao.getProposalStartTime(id) + 30 days);
        assertFalse(dao.getProposalExecuted(id));
    }

    function testFuzz_ProposalRejectsAnyRuleViolation(
        uint256 acres, uint256 beeIndex, bool solar, bool awg, bool land, bool equip, bool honey
    ) public {
        vm.assume(acres < 20 || beeIndex > 500_000 || !solar || !awg || !land || !equip || !honey);
        acres = bound(acres, 0, type(uint128).max);
        beeIndex = bound(beeIndex, 0, type(uint128).max);

        _issueLp(daoMember, 100 * 1e18);
        vm.prank(daoMember);
        vm.expectRevert();
        dao.createOffGridBeeHabitatProposal("x", acres, beeIndex, 1e18, habitatOperator, solar, awg, land, equip, honey);
    }

    /* ------------------------------ voting ------------------------------ */

    function test_VotingIsOneLpOneVote() public {
        _issueLp(daoMember, 100 * 1e18);
        _issueLp(daoMember2, 30 * 1e18);
        _issueLp(daoMember3, 20 * 1e18);

        vm.prank(daoMember);
        uint256 id = dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, habitatOperator, true, true, true, true, true);

        vm.prank(daoMember);
        dao.vote(id, true);
        vm.prank(daoMember2);
        dao.vote(id, true);
        vm.prank(daoMember3);
        dao.vote(id, false);

        assertEq(dao.getProposalForVotes(id), 130 * 1e18);
        assertEq(dao.getProposalAgainstVotes(id), 20 * 1e18);
    }

    function test_CannotVoteTwice() public {
        uint256 id = _openProposal();
        vm.prank(daoMember);
        dao.vote(id, true);
        vm.prank(daoMember);
        vm.expectRevert(BeeHabitatDAO.AlreadyVoted.selector);
        dao.vote(id, true);
    }

    function test_CannotVoteWithoutLp() public {
        uint256 id = _openProposal();
        vm.prank(unauthorizedUser);
        vm.expectRevert(BeeHabitatDAO.NoVotingPower.selector);
        dao.vote(id, true);
    }

    function test_ExpiredLpCannotVote() public {
        uint256 id = _openProposal();
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(daoMember);
        vm.expectRevert(BeeHabitatDAO.VotingInactive.selector);
        dao.vote(id, true);
    }

    function test_VotingOnlyDuringPeriod() public {
        uint256 id = _openProposal();
        vm.warp(dao.getProposalEndTime(id) + 1);
        vm.prank(daoMember);
        vm.expectRevert(BeeHabitatDAO.VotingInactive.selector);
        dao.vote(id, true);
    }

    function test_CannotVoteOnNonExistentProposal() public {
        _issueLp(daoMember, 100 * 1e18);
        vm.prank(daoMember);
        vm.expectRevert(BeeHabitatDAO.ProposalNotFound.selector);
        dao.vote(999, true);
    }

    /* ------------------------------ vault ------------------------------- */

    function test_VaultReceivesAndHoldsObs() public {
        _fundVault(VAULT_SEED);
        assertEq(dao.totalObsVaultBalance(), VAULT_SEED);
        assertEq(dao.getVaultBalance(), VAULT_SEED);
        assertEq(dao.availableVaultBalance(), VAULT_SEED);
    }

    function test_SyncVaultCreditsPlainTransfers() public {
        obs.mint(funder, 500 * 1e18);
        vm.prank(funder);
        obs.transfer(address(dao), 500 * 1e18);

        assertEq(dao.totalObsVaultBalance(), 0);
        uint256 credited = dao.syncVault();
        assertEq(credited, 500 * 1e18);
        assertEq(dao.totalObsVaultBalance(), 500 * 1e18);

        vm.expectRevert(BeeHabitatDAO.NothingToSync.selector);
        dao.syncVault();
    }

    /* -------------------- bonding curve unlock (5B DAI) ------------------ */

    function test_UnlockReadsTheCurveTrustlessly() public {
        assertEq(dao.bondingCurveDaiReserves(), 0);
        obs.setDaiReserve(1_234 * 1e18);
        assertEq(dao.bondingCurveDaiReserves(), 1_234 * 1e18);
    }

    function test_RevertIf_UnlockBelowFiveBillionDai() public {
        obs.setDaiReserve(5_000_000_000 * 1e18 - 1);
        vm.expectRevert(BeeHabitatDAO.BondingCurveTargetNotReached.selector);
        dao.checkAndUnlockVault();
        assertFalse(dao.isVaultUnlocked());
    }

    function test_UnlockAtExactlyFiveBillionDai() public {
        obs.setDaiReserve(5_000_000_000 * 1e18);
        dao.checkAndUnlockVault();
        assertTrue(dao.isVaultUnlocked());

        vm.expectRevert(BeeHabitatDAO.VaultAlreadyUnlocked.selector);
        dao.checkAndUnlockVault();
    }

    function test_NobodyCanForgeTheUnlockNumber() public {
        // The unlock takes no arguments at all - there is no caller-supplied reserve figure
        // and no oracle. Even the admin cannot unlock an under-funded curve.
        obs.setDaiReserve(0);
        vm.prank(ADMIN);
        vm.expectRevert(BeeHabitatDAO.BondingCurveTargetNotReached.selector);
        dao.checkAndUnlockVault();

        vm.prank(unauthorizedUser);
        vm.expectRevert(BeeHabitatDAO.BondingCurveTargetNotReached.selector);
        dao.checkAndUnlockVault();
    }

    function test_UnlockFailsClosedIfCurveGetterIsUnavailable() public {
        SilentObsToken silent = new SilentObsToken();
        vm.etch(OBS_TOKEN, address(silent).code);
        assertEq(dao.bondingCurveDaiReserves(), 0);
        vm.expectRevert(BeeHabitatDAO.BondingCurveTargetNotReached.selector);
        dao.checkAndUnlockVault();
    }

    /* ----------------------------- helpers ------------------------------ */

    function _openProposal() internal returns (uint256) {
        _issueLp(daoMember, 100 * 1e18);
        vm.prank(daoMember);
        return dao.createOffGridBeeHabitatProposal("x", 25, 100, 1e18, habitatOperator, true, true, true, true, true);
    }
}
