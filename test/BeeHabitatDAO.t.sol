// SPDX-License-Identifier: AGPLv3-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/BeeHabitatDAO.sol";

contract MockOBS is IBindingCurveToken {
    uint256 public raised;
    function setRaised(uint256 amount) external { raised = amount; }
    function totalRaisedDAI() external view returns (uint256) { return raised; }
}

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balances;
    function mint(address to, uint256 amount) external { balances[to] += amount; }
    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "Low balance");
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        return true;
    }
    function balanceOf(address account) external view returns (uint256) { return balances[account]; }
}

contract BeeHabitatDAOTest is Test {
    BeeHabitatDAO public dao;
    MockOBS public obs;
    MockERC20 public token;

    address master = 0xBe53702c6f57aF155410f883f38f92414d39E3d5;
    address user1 = address(0x1);
    address robot = address(0x99);
    bytes pqcKey = "dummy_pqc_public_key_64_bytes_min_length_for_testing_purposes";
    bytes validSig = "valid_pqc_signature_mock_guaranteed_to_be_over_64_bytes_long_string_for_testing_purposes";

    function setUp() public {
        obs = new MockOBS();
        token = new MockERC20();
        dao = new BeeHabitatDAO(address(obs));
    }

    function test_MembershipAndLP() public {
        vm.prank(user1);
        dao.joinDAO();

        (bool joined, ) = dao.members(user1);
        assertTrue(joined);
        assertEq(dao.getVotingPower(user1), 100 * 10**18);
    }

    function test_MilestoneAndRobotLock() public {
        obs.setRaised(5_000_000_000 * 10**18);
        dao.checkAndUnlockFunds();

        vm.prank(master);
        dao.setupRoomieRobotAndLock(robot, pqcKey);

        assertTrue(dao.systemPermanentlyLocked());
        assertEq(dao.connectedRoomieRobotAddress(), robot);
    }

    function test_BeeTargetEnforcement() public {
        obs.setRaised(5_000_000_000 * 10**18);
        dao.checkAndUnlockFunds();

        vm.prank(master);
        dao.setupRoomieRobotAndLock(robot, pqcKey);

        dao.reportAndEnforceBeeTarget(1000 * 10**18, 0, validSig);
        assertTrue(dao.beeTargetReached());
    }
}
