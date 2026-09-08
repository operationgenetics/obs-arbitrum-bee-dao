// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockObsToken} from "./Harness.sol";
import {BeeHabitatDAO} from "../contracts/BeeHabitatDAO.sol";

/**
 * @dev Drives the DAO through randomised, valid sequences of real operations, including fully
 *      correct hybrid-PQC milestone releases. Actions that would revert are skipped rather than
 *      forced, so the fuzzer explores reachable states instead of the revert surface.
 */
contract Handler is Test {
    BeeHabitatDAO public dao;
    MockObsToken public obs;

    address internal constant ADMIN = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    uint256 internal mcuPrivKey = 0xB33A17;
    bytes internal pqcPublicKey;
    uint256 internal constant OTS_LEN = 256;
    bytes32[OTS_LEN + 1] internal otsChain;
    uint256 internal otsCursor;

    /// @notice Ghost: every OBS ever credited to the vault.
    uint256 public ghostTotalDeposited;
    /// @notice Ghost: live project ids, for summing reservations.
    uint256[] public liveProjects;

    address[] internal members;

    constructor(BeeHabitatDAO _dao, MockObsToken _obs, bytes memory _pqcPublicKey, bytes32[OTS_LEN + 1] memory _chain) {
        dao = _dao;
        obs = _obs;
        pqcPublicKey = _pqcPublicKey;
        otsChain = _chain;
        otsCursor = OTS_LEN - 1;

        for (uint256 i = 0; i < 5; i++) {
            members.push(address(uint160(0xBEE0 + i)));
        }
    }

    function _member(uint256 seed) internal view returns (address) {
        return members[seed % members.length];
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1e18, 10_000_000 * 1e18);
        obs.mint(address(this), amount);
        obs.approve(address(dao), amount);
        dao.depositToVault(amount);
        ghostTotalDeposited += amount;
    }

    function issueLp(uint256 seed, uint256 amount) external {
        address to = _member(seed);
        uint256 epoch = dao.currentEpoch();
        (uint256 bal, uint256 ep) = dao.monthlyLpBalances(to);
        uint256 used = ep == epoch ? bal : 0;
        if (used >= dao.MONTHLY_LP_ISSUANCE()) return;
        amount = bound(amount, 1, dao.MONTHLY_LP_ISSUANCE() - used);

        vm.prank(ADMIN);
        dao.issueMonthlyLpTokens(to, amount);
    }

    function unlockVault() external {
        if (dao.isVaultUnlocked()) return;
        obs.setDaiReserve(dao.BONDING_CURVE_DAI_UNLOCK_TARGET());
        dao.checkAndUnlockVault();
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1 days, 75 days));
    }

    /// @dev Proposal, vote and execution as one action, so projects actually come into being.
    function fundProject(uint256 seed, uint256 fundingSeed) external {
        if (!dao.isVaultUnlocked()) return;

        uint256 available = dao.availableVaultBalance();
        uint256 maxFunding = (available * dao.MAX_PROJECT_BPS_OF_VAULT()) / dao.BPS_DENOMINATOR();
        if (maxFunding == 0) return;
        if ((dao.totalObsVaultBalance() * dao.MAX_TRANCHE_BPS_OF_VAULT()) / dao.BPS_DENOMINATOR() == 0) return;
        uint256 funding = bound(fundingSeed, 1, maxFunding);

        address proposer = _member(seed);
        uint256 epoch = dao.currentEpoch();
        (uint256 bal, uint256 ep) = dao.monthlyLpBalances(proposer);
        uint256 used = ep == epoch ? bal : 0;
        // NOTE: read every constant BEFORE vm.prank. A nested `dao.X()` in the argument list
        // would consume the prank, so the issuance would be sent by the handler and revert.
        uint256 monthlyIssuance = dao.MONTHLY_LP_ISSUANCE();
        if (used < dao.PROPOSAL_THRESHOLD()) {
            uint256 topUp = monthlyIssuance - used;
            vm.prank(ADMIN);
            dao.issueMonthlyLpTokens(proposer, topUp);
        }

        vm.prank(proposer);
        uint256 propId = dao.createOffGridBeeHabitatProposal(
            "invariant habitat", 25, 100_000, funding, address(0xFEE), true, true, true, true, true
        );
        vm.prank(proposer);
        dao.vote(propId, true);

        vm.warp(vm.getBlockTimestamp() + 31 days);
        try dao.executeProposal(propId) returns (uint256 projectId) {
            liveProjects.push(projectId);
        } catch {}
    }

    function releaseMilestone(uint256 projectSeed, uint256 amountSeed) external {
        if (liveProjects.length == 0) return;
        if (!dao.isRobotCommissioned()) return;
        if (otsCursor == 0) return;

        uint256 projectId = liveProjects[projectSeed % liveProjects.length];
        if (dao.getProjectCompleted(projectId) || dao.getProjectExpired(projectId)) return;
        if (vm.getBlockTimestamp() > dao.getProjectDeadline(projectId)) return;
        if (dao.getProjectMilestonesCompleted(projectId) >= dao.getProjectMilestoneCount(projectId)) return;
        if (vm.getBlockTimestamp() < dao.nextMilestoneUnlockTime(projectId)) return;

        uint256 cap = dao.getProjectPerMilestoneCap(projectId);
        uint256 remaining = dao.getProjectFundingRemaining(projectId);
        uint256 ceiling = dao.getProjectTrancheCeiling(projectId);
        uint256 max = cap < remaining ? cap : remaining;
        if (ceiling < max) max = ceiling;
        if (dao.totalObsVaultBalance() < max) max = dao.totalObsVaultBalance();
        if (max == 0) return;
        uint256 amount = bound(amountSeed, 1, max);

        BeeHabitatDAO.MilestoneAttestation memory att = BeeHabitatDAO.MilestoneAttestation({
            acresSecured: 25, hivesInstalled: 40, honeyKgDistributedFree: 120,
            atmosphericWaterLiters: 9_000, solarKwhGenerated: 4_200, batteryKwhStored: 800,
            beeFlourishingIndexDelta: 1_000, offGridVerified: true, landAcquired: true,
            equipmentOperational: true, evidenceHash: keccak256("evidence")
        });

        bytes memory pqcSig = new bytes(2420);
        bytes32 preimage = otsChain[otsCursor];

        bytes32 actionDigest = keccak256(
            abi.encode(
                dao.MILESTONE_TYPEHASH(), projectId, dao.getProjectMilestonesCompleted(projectId),
                amount, dao.getProjectPayoutRecipient(projectId), _attHash(att)
            )
        );
        bytes32 payload = keccak256(
            abi.encode(block.chainid, address(dao), actionDigest, dao.getRobotPqcPublicKeyHash(), keccak256(pqcSig), preimage)
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(mcuPrivKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload)));

        vm.prank(ADMIN);
        dao.robotAuthorizeAndReleaseMilestone(
            projectId, amount, att, pqcPublicKey, pqcSig, abi.encodePacked(r, s, v), preimage
        );
        otsCursor -= 1;
    }

    function timeoutProject(uint256 projectSeed) external {
        if (liveProjects.length == 0) return;
        uint256 projectId = liveProjects[projectSeed % liveProjects.length];
        if (dao.getProjectCompleted(projectId) || dao.getProjectExpired(projectId)) return;
        if (vm.getBlockTimestamp() <= dao.getProjectDeadline(projectId)) return;
        dao.checkProjectTimeout(projectId);
    }

    function _attHash(BeeHabitatDAO.MilestoneAttestation memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                a.acresSecured, a.hivesInstalled, a.honeyKgDistributedFree, a.atmosphericWaterLiters,
                a.solarKwhGenerated, a.batteryKwhStored, a.beeFlourishingIndexDelta,
                a.offGridVerified, a.landAcquired, a.equipmentOperational, a.evidenceHash
            )
        );
    }

    function liveProjectCount() external view returns (uint256) {
        return liveProjects.length;
    }
}

contract BeeHabitatDAOInvariantTest is Test {
    BeeHabitatDAO internal dao;
    MockObsToken internal obs;
    Handler internal handler;

    address internal constant OBS_TOKEN = 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;
    address internal constant ADMIN = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    uint256 internal constant OTS_LEN = 256;

    function setUp() public {
        MockObsToken impl = new MockObsToken();
        vm.etch(OBS_TOKEN, address(impl).code);
        obs = MockObsToken(OBS_TOKEN);

        dao = new BeeHabitatDAO();

        bytes memory pqcPublicKey = new bytes(1312);
        bytes32[OTS_LEN + 1] memory chain;
        chain[0] = keccak256("invariant-seed");
        for (uint256 i = 1; i <= OTS_LEN; i++) {
            chain[i] = keccak256(abi.encodePacked(chain[i - 1]));
        }

        vm.prank(ADMIN);
        dao.commissionRoomieRobot(keccak256(pqcPublicKey), vm.addr(0xB33A17), chain[OTS_LEN], uint64(OTS_LEN));

        handler = new Handler(dao, obs, pqcPublicKey, chain);
        targetContract(address(handler));
    }

    /// @notice The vault can never promise more OBS than it holds.
    function invariant_ReservationsNeverExceedVault() public view {
        assertLe(dao.totalReservedForProjects(), dao.totalObsVaultBalance());
    }

    /// @notice Internal accounting always equals the real token balance.
    function invariant_AccountingMatchesTokenBalance() public view {
        assertEq(dao.totalObsVaultBalance(), obs.balanceOf(address(dao)));
    }

    /// @notice OBS is conserved: everything deposited is either still held or was released.
    function invariant_ObsIsConserved() public view {
        assertEq(dao.totalObsVaultBalance() + dao.totalObsReleased(), handler.ghostTotalDeposited());
    }

    /// @notice Reservations equal exactly the sum of what live projects may still draw.
    function invariant_ReservationsEqualSumOfProjectRemainders() public view {
        uint256 sum;
        uint256 n = handler.liveProjectCount();
        for (uint256 i = 0; i < n; i++) {
            sum += dao.getProjectFundingRemaining(handler.liveProjects(i));
        }
        assertEq(sum, dao.totalReservedForProjects());
    }

    /// @notice No OBS can ever leave while the bonding-curve gate is shut.
    function invariant_NothingLeavesWhileVaultIsLocked() public view {
        if (!dao.isVaultUnlocked()) {
            assertEq(dao.totalObsReleased(), 0);
        }
    }

    /// @notice A project can never release more than its approved funding.
    function invariant_ProjectsNeverOverdraw() public view {
        uint256 n = handler.liveProjectCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.liveProjects(i);
            assertLe(dao.getProjectFundingRemaining(id), dao.getProjectFundingAmount(id));
            assertLe(dao.getProjectMilestonesCompleted(id), dao.getProjectMilestoneCount(id));
        }
    }

    /// @notice The flourishing index can never exceed the safe carrying-capacity cap.
    function invariant_BeeIndexStaysWithinSafeCap() public view {
        assertLe(dao.beeFlourishingIndex(), dao.OPTIMAL_BEE_INDEX_CAP());
    }
}
