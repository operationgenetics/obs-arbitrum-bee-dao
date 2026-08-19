// SPDX-License-Identifier: AGPLv3-3.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/BeeHabitatDAO.sol";

// Define the interface locally within the test file to match the contract
interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MockVaultToken is IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool) { return true; }
    function balanceOf(address account) external view returns (uint256) { return 1000 * 10**18; }
}

contract BeeHabitatDAOTest is Test {
    BeeHabitatDAO public dao;
    function setUp() public {
        dao = new BeeHabitatDAO();
    }
    
    function testDeployment() public {
        assertEq(address(dao.obsToken()), 0x2D8760e2877148d239a54952A458710553B2B54b);
    }
}
