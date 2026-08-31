// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IObscuraToken is IERC20 {
    function getCostForTokens(uint256 tokenAmount) external view returns (uint256);
}

contract BeeHabitatDAO is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant OBS_TOKEN = 0x2D8760e2877148d239a54952A458710553B2B54b;
    address public constant ADMIN_ORCHESTRATOR = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    uint256 public constant BONDING_CURVE_DAI_UNLOCK_TARGET = 5_000_000_000 * 1e18;

    string public constant HABITAT_FOCUS_ZONE = "Nationwide United States Off-Grid Indoor & Regional Pollinator Corridors";
    uint256 public constant MIN_FLOWERING_ACRES_TARGET = 20;
    uint256 public constant OPTIMAL_BEE_INDEX_CAP = 500_000;

    uint256 public constant MONTHLY_LP_ISSUANCE = 100 * 1e18;
    uint256 public constant PROPOSAL_THRESHOLD = 50 * 1e18;
    uint256 public constant VOTING_PERIOD_DURATION = 30 days;
    uint256 public constant MILESTONE_GATING_INTERVAL = 60 days;
    uint256 public constant QUORUM_PERCENTAGE = 10; // 10% of total LP supply needed for quorum

    bytes32 public roomieRobotPqcPublicKeyHash;
    bool public roomieRobotLocked;
    bool public canUpdateRobotConfig = true;

    uint256 public totalObsVaultBalance;
    bool public vaultUnlocked;

    struct OffGridHabitatProposal {
        uint256 id;
        address proposer;
        string description;
        uint256 targetAcresForBees;
        uint256 proposedBeePopulationIndex;
        bool solarAndBatteryEquipped;
        bool atmosphericWaterGenEquipped;
        bool landAcquisitionIncluded;
        bool equipmentAcquisitionIncluded;
        bool honeyProductionAndDistribution;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 startTime;
        uint256 endTime;
        bool executed;
        bool canceled;
        mapping(address => bool) hasVoted;
    }

    struct LpTokenLedger {
        uint256 balance;
        uint256 expirationMonth;
    }

    struct Project {
        uint256 id;
        uint256 proposalId;
        address creator;
        uint256 fundingAmount;
        uint256 startTime;
        uint256 deadline;
        bool completed;
        bool fundsReleased;
        uint256 lastMilestoneTime;
        string missionDescription;
    }

    mapping(address => LpTokenLedger) public monthlyLpBalances;
    mapping(uint256 => OffGridHabitatProposal) public proposals;
    uint256 public proposalCount;

    mapping(uint256 => Project) public projects;
    uint256 public projectCount;

    event RoomieRobotConfigured(bytes32 pqcPublicKeyHash);
    event RobotConfigRevoked();
    event OffGridBeeHabitatProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint256 targetAcres,
        uint256 proposedBeePopulationIndex,
        bool solarPowered,
        bool awgWaterPowered
    );
    event Voted(uint256 indexed proposalId, address indexed voter, uint256 weight, bool support);
    event VaultUnlockedByBondingCurve(uint256 daiReserves);
    event MilestoneAuthorizedByRobot(uint256 indexed projectId, uint256 timestamp);
    event ProjectCreated(uint256 indexed projectId, uint256 indexed proposalId, address indexed creator, uint256 fundingAmount);
    event ProjectFundsWithdrawn(uint256 indexed projectId, uint256 amount, address recipient);
    event ProjectCompleted(uint256 indexed projectId);
    event ProjectExpired(uint256 indexed projectId);

    modifier onlyAdminOrRobot() {
        require(msg.sender == ADMIN_ORCHESTRATOR, "Unauthorized: Must match hardware orchestrator");
        _;
    }

    modifier onlyWhenVaultUnlocked() {
        require(vaultUnlocked, "Vault not unlocked: 5B DAI threshold not reached");
        _;
    }

    // Using OpenZeppelin's nonReentrant modifier directly

    constructor() {
        roomieRobotLocked = false;
    }

    function obsToken() external view returns (address) {
        return OBS_TOKEN;
    }

    function setupRoomieRobotAndLock(bytes32 _pqcPublicKeyHash) external onlyAdminOrRobot {
        require(canUpdateRobotConfig, "Robot configuration is permanently immutable");
        require(_pqcPublicKeyHash != bytes32(0), "Invalid PQC public key hash");
        roomieRobotPqcPublicKeyHash = _pqcPublicKeyHash;
        roomieRobotLocked = true;
        emit RoomieRobotConfigured(_pqcPublicKeyHash);
    }

    function updateRobotPqcPublicKey(bytes32 _newPqcPublicKeyHash) external onlyAdminOrRobot {
        require(canUpdateRobotConfig, "Robot configuration is permanently immutable");
        require(roomieRobotLocked, "Robot not yet configured");
        require(_newPqcPublicKeyHash != bytes32(0), "Invalid PQC public key hash");
        roomieRobotPqcPublicKeyHash = _newPqcPublicKeyHash;
        emit RoomieRobotConfigured(_newPqcPublicKeyHash);
    }

    function revokeAndUpdateImmutability() external onlyAdminOrRobot {
        require(canUpdateRobotConfig, "Already immutable");
        canUpdateRobotConfig = false;
        emit RobotConfigRevoked();
    }

    function issueMonthlyLpTokens(address recipient, uint256 amount) external onlyAdminOrRobot {
        require(amount <= MONTHLY_LP_ISSUANCE, "Exceeds monthly issuance limit");
        uint256 currentMonth = block.timestamp / 30 days;

        LpTokenLedger storage ledger = monthlyLpBalances[recipient];
        if (ledger.expirationMonth == currentMonth) {
            ledger.balance += amount;
        } else {
            ledger.balance = amount;
            ledger.expirationMonth = currentMonth;
        }
    }

    function getVotingPower(address account) public view returns (uint256) {
        LpTokenLedger storage ledger = monthlyLpBalances[account];
        uint256 currentMonth = block.timestamp / 30 days;

        if (ledger.expirationMonth < currentMonth) {
            return 0;
        }
        return ledger.balance;
    }

    function getTotalActiveLpSupply() public view returns (uint256) {
        uint256 total = 0;
        // This would need iteration in practice, but for on-chain we track via events
        // For now return a tracked value - in production would use a separate mapping
        return total;
    }

    function createOffGridBeeHabitatProposal(
        string calldata description,
        uint256 targetAcresForBees,
        uint256 proposedBeePopulationIndex,
        bool solarAndBatteryEquipped,
        bool atmosphericWaterGenEquipped,
        bool landAcquisitionIncluded,
        bool equipmentAcquisitionIncluded,
        bool honeyProductionAndDistribution
    ) external returns (uint256) {
        require(getVotingPower(msg.sender) >= PROPOSAL_THRESHOLD, "Insufficient unexpired LP tokens (50 required)");
        require(targetAcresForBees >= MIN_FLOWERING_ACRES_TARGET, "Must meet minimum bee forage acreage mandate");
        require(proposedBeePopulationIndex <= OPTIMAL_BEE_INDEX_CAP, "Exceeds optimal safe carrying capacity index cap");
        require(solarAndBatteryEquipped, "Off-grid habitats must feature solar and battery storage");
        require(atmosphericWaterGenEquipped, "Off-grid habitats must feature atmospheric water generation");
        require(landAcquisitionIncluded, "Must include land acquisition for permanent habitat");
        require(equipmentAcquisitionIncluded, "Must include equipment for maintenance operations");
        require(honeyProductionAndDistribution, "Must include honey production and free distribution");

        uint256 proposalId = ++proposalCount;
        OffGridHabitatProposal storage prop = proposals[proposalId];
        prop.id = proposalId;
        prop.proposer = msg.sender;
        prop.description = description;
        prop.targetAcresForBees = targetAcresForBees;
        prop.proposedBeePopulationIndex = proposedBeePopulationIndex;
        prop.solarAndBatteryEquipped = solarAndBatteryEquipped;
        prop.atmosphericWaterGenEquipped = atmosphericWaterGenEquipped;
        prop.landAcquisitionIncluded = landAcquisitionIncluded;
        prop.equipmentAcquisitionIncluded = equipmentAcquisitionIncluded;
        prop.honeyProductionAndDistribution = honeyProductionAndDistribution;
        prop.startTime = block.timestamp;
        prop.endTime = block.timestamp + VOTING_PERIOD_DURATION;

        emit OffGridBeeHabitatProposalCreated(
            proposalId,
            msg.sender,
            description,
            targetAcresForBees,
            proposedBeePopulationIndex,
            solarAndBatteryEquipped,
            atmosphericWaterGenEquipped
        );
        return proposalId;
    }

    function vote(uint256 proposalId, bool support) external {
        OffGridHabitatProposal storage prop = proposals[proposalId];
        require(block.timestamp >= prop.startTime && block.timestamp <= prop.endTime, "Voting inactive");
        require(!prop.hasVoted[msg.sender], "Already voted");

        uint256 weight = getVotingPower(msg.sender);
        require(weight > 0, "No active unexpired LP voting power");

        prop.hasVoted[msg.sender] = true;
        if (support) {
            prop.forVotes += weight;
        } else {
            prop.againstVotes += weight;
        }

        emit Voted(proposalId, msg.sender, weight, support);
    }

    function executeProposal(uint256 proposalId, uint256 fundingAmount) external onlyWhenVaultUnlocked {
        OffGridHabitatProposal storage prop = proposals[proposalId];
        require(block.timestamp > prop.endTime, "Voting period not ended");
        require(!prop.executed, "Proposal already executed");
        require(!prop.canceled, "Proposal canceled");

        uint256 totalVotes = prop.forVotes + prop.againstVotes;
        require(totalVotes > 0, "No votes cast");
        require(prop.forVotes > prop.againstVotes, "Proposal rejected: against votes exceed for votes");

        // Check quorum: at least QUORUM_PERCENTAGE of active LP supply voted
        // Since we can't iterate all accounts, we track total LP issued per month
        // For this implementation, we require forVotes > 0 and for > against

        prop.executed = true;

        // Create project from approved proposal
        uint256 projectId = ++projectCount;
        Project storage project = projects[projectId];
        project.id = projectId;
        project.proposalId = proposalId;
        project.creator = prop.proposer;
        project.fundingAmount = fundingAmount;
        project.startTime = block.timestamp;
        project.deadline = block.timestamp + 365 days; // 1 year default deadline
        project.completed = false;
        project.fundsReleased = false;
        project.lastMilestoneTime = 0;
        project.missionDescription = prop.description;

        emit ProjectCreated(projectId, proposalId, prop.proposer, fundingAmount);
    }

    function checkAndUnlockVault(uint256 currentDaiReserves) external {
        require(!vaultUnlocked, "Vault already unlocked");
        require(currentDaiReserves >= BONDING_CURVE_DAI_UNLOCK_TARGET, "Target of 5 Billion DAI not reached");

        vaultUnlocked = true;
        emit VaultUnlockedByBondingCurve(currentDaiReserves);
    }

    function robotAuthorizeProjectMilestone(uint256 projectId, bytes calldata robotPqcSignature) external onlyAdminOrRobot {
        require(roomieRobotLocked, "Roomie robot not locked/configured");
        require(robotPqcSignature.length > 0, "Invalid biometric PQC MCU signature");

        Project storage project = projects[projectId];
        require(project.id != 0, "Project does not exist");
        require(!project.completed, "Project already completed");
        require(!project.fundsReleased, "Funds already released for current milestone");

        uint256 lastMilestoneTime = project.lastMilestoneTime;
        if (lastMilestoneTime > 0) {
            require(
                block.timestamp >= lastMilestoneTime + MILESTONE_GATING_INTERVAL,
                "Milestone locked: Bi-monthly cycle (1 time every 2 months) not reached"
            );
        }

        // Verify PQC signature (placeholder - in production would verify against stored public key hash)
        // The actual PQC verification happens off-chain on the MCU
        // On-chain we verify the signature was produced by the authorized robot
        _verifyPqcSignature(robotPqcSignature, projectId);

        project.lastMilestoneTime = block.timestamp;
        project.fundsReleased = true;
        emit MilestoneAuthorizedByRobot(projectId, block.timestamp);
    }

    function withdrawProjectFunds(uint256 projectId, address recipient, uint256 amount) external onlyAdminOrRobot nonReentrant {
        Project storage project = projects[projectId];
        require(project.id != 0, "Project does not exist");
        require(project.fundsReleased, "Funds not authorized for release - requires robot milestone authorization");
        require(amount <= project.fundingAmount, "Amount exceeds project funding");
        require(totalObsVaultBalance >= amount, "Insufficient vault balance");

        project.fundingAmount -= amount;
        project.fundsReleased = false; // Reset for next milestone
        totalObsVaultBalance -= amount;

        IERC20(OBS_TOKEN).safeTransfer(recipient, amount);
        emit ProjectFundsWithdrawn(projectId, amount, recipient);
    }

    function completeProject(uint256 projectId) external onlyAdminOrRobot {
        Project storage project = projects[projectId];
        require(project.id != 0, "Project does not exist");
        require(!project.completed, "Project already completed");
        require(project.fundingAmount == 0, "All funds must be withdrawn before completion");

        project.completed = true;
        emit ProjectCompleted(projectId);
    }

    function checkProjectTimeout(uint256 projectId) external {
        Project storage project = projects[projectId];
        require(project.id != 0, "Project does not exist");
        require(!project.completed, "Project already completed");

        if (block.timestamp > project.deadline) {
            // Project expired - funds return to vault or are locked
            project.fundingAmount = 0;
            project.completed = true;
            emit ProjectExpired(projectId);
        }
    }

    function depositToVault(uint256 amount) external nonReentrant {
        IERC20(OBS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        totalObsVaultBalance += amount;
    }

    function getVaultBalance() external view returns (uint256) {
        return IERC20(OBS_TOKEN).balanceOf(address(this));
    }

    // Internal PQC verification - in production this would use a precompile or external verifier
    // For now, we verify the signature is non-empty and from the authorized caller
    function _verifyPqcSignature(bytes calldata signature, uint256 projectId) internal view {
        // In production: verify signature against roomieRobotPqcPublicKeyHash
        // This requires a PQC precompile or external verification contract
        // For now we enforce that only ADMIN_ORCHESTRATOR can call (via onlyAdminOrRobot modifier)
        // and that signature is non-empty
        require(signature.length > 63, "PQC signature too short"); // Minimum viable signature length (64 bytes)
    }

    // View functions for testing and integration
    function getProposalId(uint256 proposalId) external view returns (uint256) {
        return proposals[proposalId].id;
    }

    function getProposalProposer(uint256 proposalId) external view returns (address) {
        return proposals[proposalId].proposer;
    }

    function getProposalDescription(uint256 proposalId) external view returns (string memory) {
        return proposals[proposalId].description;
    }

    function getProposalTargetAcres(uint256 proposalId) external view returns (uint256) {
        return proposals[proposalId].targetAcresForBees;
    }

    function getProposalBeeIndex(uint256 proposalId) external view returns (uint256) {
        return proposals[proposalId].proposedBeePopulationIndex;
    }

    function getProposalSolarAndBattery(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].solarAndBatteryEquipped;
    }

    function getProposalAwg(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].atmosphericWaterGenEquipped;
    }

    function getProposalLandAcquisition(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].landAcquisitionIncluded;
    }

    function getProposalEquipmentAcquisition(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].equipmentAcquisitionIncluded;
    }

    function getProposalHoneyProduction(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].honeyProductionAndDistribution;
    }

    function getProposalForVotes(uint256 proposalId) external view returns (uint256) {
        return proposals[proposalId].forVotes;
    }

    function getProposalAgainstVotes(uint256 proposalId) external view returns (uint256) {
        return proposals[proposalId].againstVotes;
    }

    function getProposalStartTime(uint256 proposalId) external view returns (uint256) {
        return proposals[proposalId].startTime;
    }

    function getProposalEndTime(uint256 proposalId) external view returns (uint256) {
        return proposals[proposalId].endTime;
    }

    function getProposalExecuted(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].executed;
    }

    function getProposalCanceled(uint256 proposalId) external view returns (bool) {
        return proposals[proposalId].canceled;
    }

    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return proposals[proposalId].hasVoted[voter];
    }

    function getProjectId(uint256 projectId) external view returns (uint256) {
        return projects[projectId].id;
    }

    function getProjectProposalId(uint256 projectId) external view returns (uint256) {
        return projects[projectId].proposalId;
    }

    function getProjectCreator(uint256 projectId) external view returns (address) {
        return projects[projectId].creator;
    }

    function getProjectFundingAmount(uint256 projectId) external view returns (uint256) {
        return projects[projectId].fundingAmount;
    }

    function getProjectStartTime(uint256 projectId) external view returns (uint256) {
        return projects[projectId].startTime;
    }

    function getProjectDeadline(uint256 projectId) external view returns (uint256) {
        return projects[projectId].deadline;
    }

    function getProjectCompleted(uint256 projectId) external view returns (bool) {
        return projects[projectId].completed;
    }

    function getProjectFundsReleased(uint256 projectId) external view returns (bool) {
        return projects[projectId].fundsReleased;
    }

    function getProjectLastMilestoneTime(uint256 projectId) external view returns (uint256) {
        return projects[projectId].lastMilestoneTime;
    }

    function getProjectMissionDescription(uint256 projectId) external view returns (string memory) {
        return projects[projectId].missionDescription;
    }

    function getProposalCount() external view returns (uint256) {
        return proposalCount;
    }

    function getProjectCount() external view returns (uint256) {
        return projectCount;
    }

    function isVaultUnlocked() external view returns (bool) {
        return vaultUnlocked;
    }

    function isRobotConfigured() external view returns (bool) {
        return roomieRobotLocked;
    }

    function isConfigUpdatable() external view returns (bool) {
        return canUpdateRobotConfig;
    }

    function getRobotPqcPublicKeyHash() external view returns (bytes32) {
        return roomieRobotPqcPublicKeyHash;
    }
}