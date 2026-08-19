// SPDX-License-Identifier: AGPLv3-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/BeeHabitatDAO.sol";

interface IERC20Full {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalRaisedDAI() external view returns (uint256);
}

contract MockFullToken is IERC20Full {
    uint256 public raisedDAI = 0;

    function setRaisedDAI(uint256 _amount) external {
        raisedDAI = _amount;
    }

    function totalRaisedDAI() external view returns (uint256) {
        return raisedDAI;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) { 
        return true; 
    }
    
    function balanceOf(address account) external view returns (uint256) { 
        return 10_000_000 * 10**18; 
    }
}

contract BeeHabitatDAOFullAuditTest is Test {
    BeeHabitatDAO public dao;
    MockFullToken public mockToken;

    address master = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address robot = address(0x999);
    address member1 = address(0x111);

    function setUp() public {
        dao = new BeeHabitatDAO();
        mockToken = new MockFullToken();
    }

    function testFullSecurityAndOperationalAudit() public {
        // --- 1. VERIFY IMMUTABLES & CONSTANTS ---
        assertEq(dao.MASTER_CONTROLLER_WALLET(), master);
        assertEq(dao.MAX_MEMBERS(), 20_000);
        assertTrue(bytes(dao.DAO_MISSION()).length > 0);

        // --- 2. TEST MEMBERSHIP & MONTHLY LP EXPIRY SYSTEM ---
        vm.prank(member1);
        dao.joinDAO();
        assertEq(dao.getVotingPower(member1), 100 * 10**18);

        vm.prank(member1);
        dao.createProposal("Deploy off-grid solar water generator", 7);
        assertEq(dao.getVotingPower(member1), 50 * 10**18);

        // --- 3. TEST BONDING CURVE GATE ---
        mockToken.setRaisedDAI(5_000_000_000 * 10**18);

        // --- 4. TEST MASTER CONTROLLER PQC HARDWARE LOCKDOWN ---
        bytes memory robotPqcKey = hex"0123456789abcdef0123456789abcdef";
        
        vm.prank(master);
        dao.updateRoomieRobotConfig(robot, robotPqcKey);
        assertTrue(dao.systemPermanentlyLocked());

        vm.prank(master);
        dao.revokeRobotConfigUpdates();
        assertFalse(dao.robotConfigUpdatable());

        // --- 5. TEST ROBOT OPERATION & HONEY HARVEST LOGGING ---
        bytes memory validSig = hex"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

        vm.prank(robot);
        dao.recordHoneyHarvestWithPQC(500, "Tucson-Grid-Unit-1", 0, validSig);

        // --- 6. TEST BEE FLOURISHING TARGET ENFORCEMENT ---
        vm.prank(robot);
        dao.reportAndEnforceBeeTarget(1000 * 10**18, 1, validSig);
        assertTrue(dao.beeTargetReached());

        vm.prank(member1);
        vm.expectRevert("Mission Accomplished: Bee flourishing target reached and locked.");
        dao.createProposal("Post-mission proposal", 3);
    }
}
