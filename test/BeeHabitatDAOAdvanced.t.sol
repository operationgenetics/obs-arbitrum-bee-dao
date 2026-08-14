// SPDX-License-Identifier: AGPLv3-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/BeeHabitatDAO.sol";

contract MockBindingCurve is IBindingCurveToken {
    uint256 public totalRaisedDAI = 0;
    mapping(address => uint256) public balanceOf;

    function setTotalRaisedDAI(uint256 _raised) external {
        totalRaisedDAI = _raised;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract MockERC20Token is IERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}

contract BeeHabitatDAOAdvancedTest is Test {
    BeeHabitatDAO public dao;
    MockBindingCurve public bondingCurve;
    MockERC20Token public rewardToken;

    address constant MASTER_ADMIN = 0xBe53702c6f57aF155410f883f38f92414d39E3d5;
    address public roomieRobot = address(0x999);
    address public member1 = address(0x1);
    address public member2 = address(0x2);
    address public attacker = address(0xBAD);

    bytes public pqcPublicKey = hex"deadbeef1234567890abcdef";

    function setUp() public {
        bondingCurve = new MockBindingCurve();
        rewardToken = new MockERC20Token();
        dao = new BeeHabitatDAO(address(bondingCurve));
    }

    function test_FullLifecycleAndSecurity() public {
        // 1. Initial State & Governance Access Control
        vm.prank(member1);
        dao.joinDAO();
        (bool joined,) = dao.members(member1);
        assertTrue(joined);
        assertEq(dao.getVotingPower(member1), 100 * 10**18);

        // Prevent double joining
        vm.prank(member1);
        vm.expectRevert("Already a member");
        dao.joinDAO();

        // 2. Proposal Creation & Voting Validation
        vm.prank(member1);
        dao.createProposal("Deploy 50 off-grid solar generators and atmospheric water modules", 7);
        
        (uint256 id, address proposer, , , , , uint256 costPaid, uint256 voterCount, bool executed) = dao.getProposalDetails(1);
        assertEq(id, 1);
        assertEq(proposer, member1);
        assertEq(costPaid, 50 * 10**18);
        assertEq(voterCount, 0);
        assertFalse(executed);

        // Member 2 joins and votes
        vm.prank(member2);
        dao.joinDAO();

        vm.prank(member2);
        dao.vote(1, true);

        address[] memory voters = dao.getProposalVoters(1);
        assertEq(voters.length, 1);
        assertEq(voters[0], member2);

        // Double voting prevention
        vm.prank(member2);
        vm.expectRevert("Already voted");
        dao.vote(1, true);

        // 3. Funds Unlocking via Bonding Curve Milestone
        assertFalse(dao.fundsUnlocked());
        bondingCurve.setTotalRaisedDAI(5_000_000_000 * 10**18);
        assertTrue(dao.checkAndUnlockFunds());
        assertTrue(dao.fundsUnlocked());

        // 4. Roomie Robot Setup & Master Controller Enforcement
        vm.prank(attacker);
        vm.expectRevert("Unauthorized");
        dao.setupRoomieRobotAndLock(roomieRobot, pqcPublicKey);

        vm.prank(MASTER_ADMIN);
        dao.setupRoomieRobotAndLock(roomieRobot, pqcPublicKey);
        assertTrue(dao.systemPermanentlyLocked());

        // 5. PQC Secure Operations (Token Disbursement)
        rewardToken.mint(address(dao), 10_000 * 10**18);

        uint256 nonce = dao.robotExecutionNonce();
        string memory missionLog = "Deploying atmospheric water generator unit at Tucson Sector Alpha";
        bytes32 messageHash = keccak256(abi.encodePacked(roomieRobot, address(rewardToken), member1, 500 * 10**18, nonce, missionLog));
        bytes memory validSig = abi.encodePacked(messageHash, bytes32(uint256(1)));

        // Unauthorized caller trying to impersonate robot execution
        vm.prank(attacker);
        vm.expectRevert("PQC Failure");
        dao.executeRobotOperationsWithPQC(address(rewardToken), member1, 500 * 10**18, nonce, missionLog, validSig);

        // Valid execution by roomie robot
        vm.prank(roomieRobot);
        dao.executeRobotOperationsWithPQC(address(rewardToken), member1, 500 * 10**18, nonce, missionLog, validSig);
        assertEq(rewardToken.balanceOf(member1), 500 * 10**18);

        // 6. Honey Harvest Logging & Non-Profit Enforcement
        uint256 harvestNonce = dao.robotExecutionNonce();
        string memory locationTag = "Tucson Smart Hive Module #4 - Surplus Extraction";
        bytes32 harvestMsgHash = keccak256(abi.encodePacked(roomieRobot, uint256(2500), locationTag, harvestNonce));
        bytes memory harvestSig = abi.encodePacked(harvestMsgHash, bytes32(uint256(1)));

        vm.prank(roomieRobot);
        dao.recordHoneyHarvestWithPQC(2500, locationTag, harvestNonce, harvestSig);
        
        assertEq(dao.totalHoneyHarvestedGrams(), 2500);
        (uint256 hId, uint256 weight, , , bool ecologicalOnly) = dao.honeyHarvests(1);
        assertEq(hId, 1);
        assertEq(weight, 2500);
        assertTrue(ecologicalOnly);

        // 7. Bee Flourishing Target & Mission Lock Enforcement
        uint256 targetNonce = dao.robotExecutionNonce();
        uint256 targetIndex = 1000 * 10**18;
        bytes32 targetMsgHash = keccak256(abi.encodePacked(roomieRobot, targetIndex, targetNonce));
        bytes memory targetSig = abi.encodePacked(targetMsgHash, bytes32(uint256(1)));

        vm.prank(roomieRobot);
        dao.reportAndEnforceBeeTarget(targetIndex, targetNonce, targetSig);

        assertTrue(dao.beeTargetReached());

        // Verify that governance actions lock down upon mission completion
        vm.prank(member1);
        vm.expectRevert("Mission Accomplished: Bee flourishing target reached and locked.");
        dao.createProposal("Post-mission proposal", 1);
    }
}
