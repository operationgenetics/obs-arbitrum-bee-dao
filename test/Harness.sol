// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BeeHabitatDAO} from "../contracts/BeeHabitatDAO.sol";

/// @dev Stand-in for the real Obscura token at 0xa473..., exposing the same bonding-curve getter.
contract MockObsToken {
    string public name = "Obscura";
    string public symbol = "OBS";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public daiReserve;
    uint256 public totalDaiCollected;

    function setDaiReserve(uint256 v) external {
        daiReserve = v;
        totalDaiCollected = v;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A token whose bonding-curve getters revert, to prove the DAO fails closed.
contract SilentObsToken {
    mapping(address => uint256) public balanceOf;
    function transfer(address, uint256) external pure returns (bool) { return true; }
    function transferFrom(address, address, uint256) external pure returns (bool) { return true; }
}

abstract contract BeeHabitatHarness is Test {
    BeeHabitatDAO internal dao;
    MockObsToken internal obs;

    address internal constant OBS_TOKEN = 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;
    address internal constant ADMIN = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    address internal unauthorizedUser = makeAddr("unauthorizedUser");
    address internal daoMember = makeAddr("daoMember");
    address internal daoMember2 = makeAddr("daoMember2");
    address internal daoMember3 = makeAddr("daoMember3");
    address internal habitatOperator = makeAddr("habitatOperator");
    address internal funder = makeAddr("funder");

    // --- Roomie MCU simulated credential ---
    uint256 internal mcuPrivKey = 0xB33A17;
    address internal mcuSigner;
    bytes internal pqcPublicKey;
    bytes32 internal pqcPublicKeyHash;

    uint256 internal constant OTS_LEN = 64;
    bytes32[OTS_LEN + 1] internal otsChain; // otsChain[0] = seed ... otsChain[OTS_LEN] = published tip
    uint256 internal otsCursor;             // index of the next link to reveal

    uint256 internal constant VAULT_SEED = 1_000_000 * 1e18;

    function _installObs() internal {
        MockObsToken impl = new MockObsToken();
        vm.etch(OBS_TOKEN, address(impl).code);
        obs = MockObsToken(OBS_TOKEN);
    }

    function _buildMcuCredential() internal {
        mcuSigner = vm.addr(mcuPrivKey);
        // A realistically-sized PQC public key (ML-DSA-44 is 1312 bytes).
        pqcPublicKey = new bytes(1312);
        for (uint256 i = 0; i < 1312; i++) {
            pqcPublicKey[i] = bytes1(uint8(uint256(keccak256(abi.encodePacked("pqc-pk", i)))));
        }
        pqcPublicKeyHash = keccak256(pqcPublicKey);

        otsChain[0] = keccak256("roomie-mcu-ots-seed");
        for (uint256 i = 1; i <= OTS_LEN; i++) {
            otsChain[i] = keccak256(abi.encodePacked(otsChain[i - 1]));
        }
        otsCursor = OTS_LEN - 1;
    }

    function setUp() public virtual {
        _installObs();
        _buildMcuCredential();
        dao = new BeeHabitatDAO();
    }

    /* ------------------------- convenience actions ------------------------- */

    function _commissionRobot() internal {
        vm.prank(ADMIN);
        dao.commissionRoomieRobot(pqcPublicKeyHash, mcuSigner, otsChain[OTS_LEN], uint64(OTS_LEN));
    }

    function _fundVault(uint256 amount) internal {
        obs.mint(funder, amount);
        vm.startPrank(funder);
        obs.approve(address(dao), amount);
        dao.depositToVault(amount);
        vm.stopPrank();
    }

    function _unlockVault() internal {
        obs.setDaiReserve(dao.BONDING_CURVE_DAI_UNLOCK_TARGET());
        dao.checkAndUnlockVault();
    }

    function _issueLp(address to, uint256 amount) internal {
        vm.prank(ADMIN);
        dao.issueMonthlyLpTokens(to, amount);
    }

    function _validPqcSignature() internal pure returns (bytes memory sig) {
        sig = new bytes(2420); // ML-DSA-44 signature size
        for (uint256 i = 0; i < 2420; i++) {
            sig[i] = bytes1(uint8(uint256(keccak256(abi.encodePacked("pqc-sig", i)))));
        }
    }

    function _goodAttestation() internal pure returns (BeeHabitatDAO.MilestoneAttestation memory a) {
        a = BeeHabitatDAO.MilestoneAttestation({
            acresSecured: 25,
            hivesInstalled: 40,
            honeyKgDistributedFree: 120,
            atmosphericWaterLiters: 9_000,
            solarKwhGenerated: 4_200,
            batteryKwhStored: 800,
            beeFlourishingIndexDelta: 10_000,
            offGridVerified: true,
            landAcquired: true,
            equipmentOperational: true,
            evidenceHash: keccak256("roomie-evidence-bundle")
        });
    }

    function _attestationHash(BeeHabitatDAO.MilestoneAttestation memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                a.acresSecured,
                a.hivesInstalled,
                a.honeyKgDistributedFree,
                a.atmosphericWaterLiters,
                a.solarKwhGenerated,
                a.batteryKwhStored,
                a.beeFlourishingIndexDelta,
                a.offGridVerified,
                a.landAcquired,
                a.equipmentOperational,
                a.evidenceHash
            )
        );
    }

    /// @dev Reproduces the contract's hybrid digest and signs it with the simulated MCU key.
    function _mcuSign(
        uint256 projectId,
        uint256 amount,
        BeeHabitatDAO.MilestoneAttestation memory att,
        bytes memory pqcSig,
        bytes32 otsPreimage,
        uint256 signingKey
    ) internal returns (bytes memory) {
        bytes32 actionDigest = keccak256(
            abi.encode(
                dao.MILESTONE_TYPEHASH(),
                projectId,
                dao.getProjectMilestonesCompleted(projectId),
                amount,
                dao.getProjectPayoutRecipient(projectId),
                _attestationHash(att)
            )
        );
        bytes32 payload = keccak256(
            abi.encode(
                block.chainid,
                address(dao),
                actionDigest,
                dao.getRobotPqcPublicKeyHash(),
                keccak256(pqcSig),
                otsPreimage
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Full, correctly-authorised milestone release.
    function _releaseMilestone(uint256 projectId, uint256 amount) internal {
        BeeHabitatDAO.MilestoneAttestation memory att = _goodAttestation();
        bytes memory pqcSig = _validPqcSignature();
        bytes32 preimage = otsChain[otsCursor];
        bytes memory ecdsaSig = _mcuSign(projectId, amount, att, pqcSig, preimage, mcuPrivKey);

        vm.prank(ADMIN);
        dao.robotAuthorizeAndReleaseMilestone(projectId, amount, att, pqcPublicKey, pqcSig, ecdsaSig, preimage);
        otsCursor -= 1;
    }

    /// @dev Creates a proposal, passes it, and executes it. Returns the project id.
    function _passProposal(uint256 requestedFunding) internal returns (uint256 projectId) {
        _issueLp(daoMember, 100 * 1e18);
        vm.prank(daoMember);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "Off-grid indoor bee habitat, AWG + solar + battery, free honey",
            25,
            250_000,
            requestedFunding,
            habitatOperator,
            true, true, true, true, true
        );
        vm.prank(daoMember);
        dao.vote(propId, true);
        vm.warp(vm.getBlockTimestamp() + 31 days);
        projectId = dao.executeProposal(propId);
    }
}
