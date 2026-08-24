// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IObscuraToken is IERC20 {
    function getCostForTokens(uint256 tokenAmount) external view returns (uint256);
}

contract BeeHabitatDAO is ReentrancyGuard {
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

    mapping(address => LpTokenLedger) public monthlyLpBalances;
    mapping(uint256 => OffGridHabitatProposal) public proposals;
    uint256 public proposalCount;

    mapping(uint256 => uint256) public projectMilestoneTimeouts;
    mapping(uint256 => bool) public projectFundReleased;

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

    modifier onlyAdminOrRobot() {
        require(msg.sender == ADMIN_ORCHESTRATOR, "Unauthorized: Must match hardware orchestrator");
        _;
    }

    constructor() {
        roomieRobotLocked = false;
    }

    function setupRoomieRobotAndLock(bytes32 _pqcPublicKeyHash) external onlyAdminOrRobot {
        require(canUpdateRobotConfig, "Robot configuration is permanently immutable");
        roomieRobotPqcPublicKeyHash = _pqcPublicKeyHash;
        roomieRobotLocked = true;
        emit RoomieRobotConfigured(_pqcPublicKeyHash);
    }

    function revokeAndUpdateImmutability() external onlyAdminOrRobot {
        require(canUpdateRobotConfig, "Already immutable");
        canUpdateRobotConfig = false;
        emit RobotConfigRevoked();
    }

    function issueMonthlyLpTokens(address recipient, uint256 amount) external onlyAdminOrRobot {
        require(amount <= MONTHLY_LP_ISSUANCE, "Exceeds monthly issuance limit");
        uint256 currentMonth = block.timestamp / 30 days;
        
        monthlyLpBalances[recipient] = LpTokenLedger({
            balance: amount,
            expirationMonth: currentMonth
        });
    }

    function getVotingPower(address account) public view returns (uint256) {
        LpTokenLedger memory ledger = monthlyLpBalances[account];
        uint256 currentMonth = block.timestamp / 30 days;
        
        if (ledger.expirationMonth < currentMonth) {
            return 0;
        }
        return ledger.balance;
    }

    function createOffGridBeeHabitatProposal(
        string calldata description, 
        uint256 targetAcresForBees,
        uint256 proposedBeePopulationIndex,
        bool solarAndBatteryEquipped,
        bool atmosphericWaterGenEquipped
    ) external returns (uint256) {
        require(getVotingPower(msg.sender) >= PROPOSAL_THRESHOLD, "Insufficient unexpired LP tokens (50 required)");
        require(targetAcresForBees >= MIN_FLOWERING_ACRES_TARGET, "Must meet minimum bee forage acreage mandate");
        require(proposedBeePopulationIndex <= OPTIMAL_BEE_INDEX_CAP, "Exceeds optimal safe carrying capacity index cap");
        require(solarAndBatteryEquipped, "Off-grid habitats must feature solar and battery storage");
        require(atmosphericWaterGenEquipped, "Off-grid habitats must feature atmospheric water generation");

        uint256 proposalId = ++proposalCount;
        OffGridHabitatProposal storage prop = proposals[proposalId];
        prop.id = proposalId;
        prop.proposer = msg.sender;
        prop.description = description;
        prop.targetAcresForBees = targetAcresForBees;
        prop.proposedBeePopulationIndex = proposedBeePopulationIndex;
        prop.solarAndBatteryEquipped = solarAndBatteryEquipped;
        prop.atmosphericWaterGenEquipped = atmosphericWaterGenEquipped;
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

    function checkAndUnlockVault(uint256 currentDaiReserves) external {
        require(!vaultUnlocked, "Vault already unlocked");
        require(currentDaiReserves >= BONDING_CURVE_DAI_UNLOCK_TARGET, "Target of 5 Billion DAI not reached");
        
        vaultUnlocked = true;
        emit VaultUnlockedByBondingCurve(currentDaiReserves);
    }

    function robotAuthorizeProjectMilestone(uint256 projectId, bytes calldata robotPqcSignature) external onlyAdminOrRobot {
        require(roomieRobotLocked, "Roomie robot not locked/configured");
        
        uint256 lastMilestoneTime = projectMilestoneTimeouts[projectId];
        if (lastMilestoneTime > 0) {
            require(
                block.timestamp >= lastMilestoneTime + MILESTONE_GATING_INTERVAL,
                "Milestone locked: Bi-monthly cycle (1 time every 2 months) not reached"
            );
        }
        require(robotPqcSignature.length > 0, "Invalid biometric PQC MCU signature");

        projectMilestoneTimeouts[projectId] = block.timestamp;
        projectFundReleased[projectId] = true;
        emit MilestoneAuthorizedByRobot(projectId, block.timestamp);
    }

    function depositToVault(uint256 amount) external nonReentrant {
        require(IERC20(OBS_TOKEN).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        totalObsVaultBalance += amount;
    }
}
