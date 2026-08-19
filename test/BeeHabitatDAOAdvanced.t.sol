// SPDX-License-Identifier: AGPLv3-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/BeeHabitatDAO.sol";

interface IERC20Advanced {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MockVaultTokenAdvanced is IERC20Advanced {
    function transfer(address recipient, uint256 amount) external returns (bool) { return true; }
    function balanceOf(address account) external view returns (uint256) { return 5_000_000_000 * 10**18; }
}

contract BeeHabitatDAOAdvancedTest is Test {
    BeeHabitatDAO public dao;
    function setUp() public {
        dao = new BeeHabitatDAO();
    }
    
    function testAdvancedDeployment() public {
        assertEq(address(dao.obsToken()), 0x2D8760e2877148d239a54952A458710553B2B54b);
    }
}
