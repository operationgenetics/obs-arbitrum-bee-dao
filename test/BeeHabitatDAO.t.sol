// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BeeHabitatDAO} from "../contracts/BeeHabitatDAO.sol";

contract BeeHabitatDAOTest is Test {
    BeeHabitatDAO dao;

    address adminOrchestrator = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address unauthorizedUser = makeAddr("unauthorizedUser");
    address daoMember = makeAddr("daoMember");

    bytes32 constant DUMMY_PQC_KEY = keccak256("PQC_DILITHIUM_KEY_V1");

    function setUp() public {
        dao = new BeeHabitatDAO();
    }

    function test_ConstantsAndInitialState() public view {
        assertEq(dao.ADMIN_ORCHESTRATOR(), adminOrchestrator);
        assertEq(dao.OPTIMAL_BEE_INDEX_CAP(), 500_000);
        assertEq(dao.MIN_FLOWERING_ACRES_TARGET(), 20);
        assertFalse(dao.roomieRobotLocked());
    }

    function test_RevertIf_UnauthorizedRobotSetup() public {
        vm.prank(unauthorizedUser);
        vm.expectRevert("Unauthorized: Must match hardware orchestrator");
        dao.setupRoomieRobotAndLock(DUMMY_PQC_KEY);
    }

    function test_AuthorizedRobotSetupAndImmutability() public {
        vm.prank(adminOrchestrator);
        dao.setupRoomieRobotAndLock(DUMMY_PQC_KEY);

        assertTrue(dao.roomieRobotLocked());
        assertEq(dao.roomieRobotPqcPublicKeyHash(), DUMMY_PQC_KEY);

        vm.prank(adminOrchestrator);
        dao.revokeAndUpdateImmutability();

        assertFalse(dao.canUpdateRobotConfig());

        vm.prank(adminOrchestrator);
        vm.expectRevert("Robot configuration is permanently immutable");
        dao.setupRoomieRobotAndLock(keccak256("NEW_KEY"));
    }

    function test_MonthlyLpIssuanceAndExpiration() public {
        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 100 * 1e18);

        assertEq(dao.getVotingPower(daoMember), 100 * 1e18);

        skip(31 days);

        assertEq(dao.getVotingPower(daoMember), 0);
    }

    function testFuzz_ProposalConstraints(uint256 acres, uint256 beeIndex, bool solar, bool awg) public {
        vm.assume(acres < 20 || beeIndex > 500_000 || !solar || !awg);

        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 100 * 1e18);

        vm.prank(daoMember);
        vm.expectRevert();
        dao.createOffGridBeeHabitatProposal(
            "Fuzz Test Habitat",
            acres,
            beeIndex,
            solar,
            awg
        );
    }

    function test_ValidOffGridProposalCreation() public {
        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 100 * 1e18);

        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "Tucson Off-Grid Pollinator Corridor Module 1",
            25,          
            450_000,     
            true,        
            true         
        );

        assertEq(propId, 1);
    }

    function test_BiMonthlyRobotMilestoneGating() public {
        vm.prank(adminOrchestrator);
        dao.setupRoomieRobotAndLock(DUMMY_PQC_KEY);

        bytes memory mockSignature = hex"12345678";

        // Warp past block 0 so initial milestone gating check passes
        skip(1 days);

        // First release should succeed
        vm.prank(adminOrchestrator);
        dao.robotAuthorizeProjectMilestone(1, mockSignature);
        assertTrue(dao.projectFundReleased(1));

        // Immediate second release attempt within the same 60-day window must fail
        vm.expectRevert("Milestone locked: Bi-monthly cycle (1 time every 2 months) not reached");
        vm.prank(adminOrchestrator);
        dao.robotAuthorizeProjectMilestone(1, mockSignature);

        // Warp time past the 60-day interval requirement
        skip(61 days);

        // Subsequent release after interval should succeed
        vm.prank(adminOrchestrator);
        dao.robotAuthorizeProjectMilestone(1, mockSignature);
    }

    function test_BondingCurveVaultUnlock() public {
        assertFalse(dao.vaultUnlocked());

        vm.expectRevert("Target of 5 Billion DAI not reached");
        dao.checkAndUnlockVault(4_999_999_999 * 1e18);

        dao.checkAndUnlockVault(5_000_000_000 * 1e18);
        assertTrue(dao.vaultUnlocked());
    }
}
