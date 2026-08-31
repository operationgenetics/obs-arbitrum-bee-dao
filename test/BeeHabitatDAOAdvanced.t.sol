// SPDX-License-Identifier: AGPLv3-3.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/BeeHabitatDAO.sol";

contract BeeHabitatDAOAdvancedTest is Test {
    BeeHabitatDAO public dao;
    address adminOrchestrator = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address daoMember = makeAddr("daoMember");
    bytes32 constant DUMMY_PQC_KEY = keccak256("PQC_DILITHIUM_KEY_V1");
    bytes constant VALID_SIGNATURE = hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

    function setUp() public {
        dao = new BeeHabitatDAO();
    }
    
    function testAdvancedDeployment() public {
        assertEq(dao.obsToken(), 0x2D8760e2877148d239a54952A458710553B2B54b);
        assertEq(dao.ADMIN_ORCHESTRATOR(), adminOrchestrator);
    }

    function test_MissionEnforcementInProposals() public {
        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 100 * 1e18);

        // Valid proposal with all mission criteria
        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "Complete Off-Grid Bee Habitat",
            50, // acres
            400_000, // bee index
            true, // solar + battery
            true, // atmospheric water generation
            true, // land acquisition
            true, // equipment acquisition
            true  // honey production & free distribution
        );

        assertEq(propId, 1);
    }

    function test_MissionCriteriaCannotBeBypassed() public {
        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 100 * 1e18);

        // Each mission criterion is mandatory
        vm.prank(daoMember);
        vm.expectRevert("Off-grid habitats must feature solar and battery storage");
        dao.createOffGridBeeHabitatProposal("Test", 25, 450_000, false, true, true, true, true);

        vm.prank(daoMember);
        vm.expectRevert("Off-grid habitats must feature atmospheric water generation");
        dao.createOffGridBeeHabitatProposal("Test", 25, 450_000, true, false, true, true, true);

        vm.prank(daoMember);
        vm.expectRevert("Must include land acquisition for permanent habitat");
        dao.createOffGridBeeHabitatProposal("Test", 25, 450_000, true, true, false, true, true);

        vm.prank(daoMember);
        vm.expectRevert("Must include equipment for maintenance operations");
        dao.createOffGridBeeHabitatProposal("Test", 25, 450_000, true, true, true, false, true);

        vm.prank(daoMember);
        vm.expectRevert("Must include honey production and free distribution");
        dao.createOffGridBeeHabitatProposal("Test", 25, 450_000, true, true, true, true, false);
    }

    function test_BeeIndexCapEnforced() public {
        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 100 * 1e18);

        vm.prank(daoMember);
        vm.expectRevert("Exceeds optimal safe carrying capacity index cap");
        dao.createOffGridBeeHabitatProposal(
            "Test",
            25,
            500_001, // Exceeds cap
            true,
            true,
            true,
            true,
            true
        );
    }

    function test_MinimumAcreageEnforced() public {
        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 100 * 1e18);

        vm.prank(daoMember);
        vm.expectRevert("Must meet minimum bee forage acreage mandate");
        dao.createOffGridBeeHabitatProposal(
            "Test",
            19, // Below minimum
            450_000,
            true,
            true,
            true,
            true,
            true
        );
    }

    function test_LpAccumulationWithinMonth() public {
        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 50 * 1e18);
        assertEq(dao.getVotingPower(daoMember), 50 * 1e18);

        // Add more within same month
        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 30 * 1e18);
        assertEq(dao.getVotingPower(daoMember), 80 * 1e18);

        // Cannot exceed monthly limit in single issuance
        vm.expectRevert("Exceeds monthly issuance limit");
        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 101 * 1e18);
    }

    function test_RobotKeyRotationBeforeRevocation() public {
        vm.prank(adminOrchestrator);
        dao.setupRoomieRobotAndLock(DUMMY_PQC_KEY);
        assertEq(dao.getRobotPqcPublicKeyHash(), DUMMY_PQC_KEY);

        // Rotate key
        bytes32 newKey = keccak256("NEW_ROBOT_KEY_V2");
        vm.prank(adminOrchestrator);
        dao.updateRobotPqcPublicKey(newKey);
        assertEq(dao.getRobotPqcPublicKeyHash(), newKey);

        // Can rotate multiple times before revocation
        bytes32 newerKey = keccak256("NEW_ROBOT_KEY_V3");
        vm.prank(adminOrchestrator);
        dao.updateRobotPqcPublicKey(newerKey);
        assertEq(dao.getRobotPqcPublicKeyHash(), newerKey);
    }

    function test_RobotKeyRotationAfterRevocationFails() public {
        vm.prank(adminOrchestrator);
        dao.setupRoomieRobotAndLock(DUMMY_PQC_KEY);
        vm.prank(adminOrchestrator);
        dao.revokeAndUpdateImmutability();

        vm.expectRevert("Robot configuration is permanently immutable");
        vm.prank(adminOrchestrator);
        dao.updateRobotPqcPublicKey(keccak256("NEW_KEY"));
    }

    function test_FullProposalLifecycle() public {
        // Unlock vault
        dao.checkAndUnlockVault(5_000_000_000 * 1e18);

        // Setup robot
        vm.prank(adminOrchestrator);
        dao.setupRoomieRobotAndLock(DUMMY_PQC_KEY);

        // Issue LP tokens
        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 100 * 1e18);

        // Create proposal
        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "Solar-Powered Bee Sanctuary with AWG",
            30,
            300_000,
            true,
            true,
            true,
            true,
            true
        );

        // Vote
        vm.prank(daoMember);
        dao.vote(propId, true);

        // Wait for voting period
        skip(31 days);

        // Execute proposal (creates project)
        vm.prank(adminOrchestrator);
        dao.executeProposal(propId, 5_000 * 1e18);

        assertEq(dao.getProjectCount(), 1);

        // Robot authorizes first milestone
        vm.prank(adminOrchestrator);
        dao.robotAuthorizeProjectMilestone(1, VALID_SIGNATURE);

        assertTrue(dao.getProjectFundsReleased(1));

        // Wait 60 days for next milestone
        skip(61 days);

        // Still fails because funds still released from first milestone
        // (withdrawal would reset this, but requires token balance)
        vm.expectRevert("Funds already released for current milestone");
        vm.prank(adminOrchestrator);
        dao.robotAuthorizeProjectMilestone(1, VALID_SIGNATURE);
    }

    function test_TwoMonthAuthorizationCycleEnforced() public {
        dao.checkAndUnlockVault(5_000_000_000 * 1e18);
        vm.prank(adminOrchestrator);
        dao.setupRoomieRobotAndLock(DUMMY_PQC_KEY);

        vm.prank(adminOrchestrator);
        dao.issueMonthlyLpTokens(daoMember, 100 * 1e18);

        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "Test",
            25,
            450_000,
            true,
            true,
            true,
            true,
            true
        );

        vm.prank(daoMember);
        dao.vote(propId, true);

        skip(31 days);

        vm.prank(adminOrchestrator);
        dao.executeProposal(propId, 1000 * 1e18);

        // First authorization
        vm.prank(adminOrchestrator);
        dao.robotAuthorizeProjectMilestone(1, VALID_SIGNATURE);

        // Try again immediately - should fail (funds already released)
        vm.expectRevert("Funds already released for current milestone");
        vm.prank(adminOrchestrator);
        dao.robotAuthorizeProjectMilestone(1, VALID_SIGNATURE);

        // Wait 59 days - should still fail (funds still released)
        skip(59 days);
        vm.expectRevert("Funds already released for current milestone");
        vm.prank(adminOrchestrator);
        dao.robotAuthorizeProjectMilestone(1, VALID_SIGNATURE);

        // Wait 1 more day (60 total) - still fails because funds still released
        skip(1 days);
        vm.expectRevert("Funds already released for current milestone");
        vm.prank(adminOrchestrator);
        dao.robotAuthorizeProjectMilestone(1, VALID_SIGNATURE);
    }
}