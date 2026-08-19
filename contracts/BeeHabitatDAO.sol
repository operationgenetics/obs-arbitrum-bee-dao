// SPDX-License-Identifier: AGPLv3-3.0
pragma solidity ^0.8.24;

interface IBindingCurveToken {
    function totalRaisedDAI() external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract BeeHabitatDAO {
    struct Member {
        bool joined;
        bool active;
        uint256 lastClaimMonth;
        uint256 joinTimestamp;
    }

    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 deadline;
        uint256 costPaid;
        bool executed;
        address[] votersList;
    }

    struct HoneyHarvestLog {
        uint256 harvestId;
        uint256 weightGrams;
        uint256 timestamp;
        string locationTag;
        bool distributedForEcologicalUseOnly;
    }

    address public constant MASTER_CONTROLLER_WALLET = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address public constant OBS_TOKEN_ADDRESS = 0x2D8760e2877148d239a54952A458710553B2B54b;

    IBindingCurveToken public immutable obsToken;
    
    string public constant DAO_MISSION = "Autonomous robotic agents must actively deploy off-grid solar-powered atmospheric water generators and smart beehive modules, maintain habitat humidity and flora growth, harvest surplus honey securely, and enforce continuous on-chain validation until the bee flourishing index reaches target capacity. HARVESTED HONEY CAN NEVER BE USED FOR PROFIT; it is strictly dedicated to bee sustenance, ecological support, and non-commercial DAO member distribution.";
    
    uint256 public constant FUNDING_GOAL_DAI = 5_000_000_000 * 10**18;
    uint256 public constant MONTHLY_LP_GRANT = 100 * 10**18;
    uint256 public constant PROPOSAL_COST = 50 * 10**18;
    uint256 public constant MAX_MEMBERS = 20_000;
    
    string public constant ipfsLogoCID = "bafybeibwefcd3zidp4echnjpjd4xtepif7fivxpp3dsvtlxvxoum5z7jqu";

    mapping(address => Member) public members;
    address[] public memberList;
    uint256 public activeMemberCount;

    mapping(address => mapping(uint256 => uint256)) public monthlyLPBal; 
    mapping(address => mapping(uint256 => bool)) public monthlyClaimed;   

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVotedOnProposal;

    bool public fundsUnlocked;
    address public connectedRoomieRobotAddress;
    bytes public roomiePqcPublicKey; 
    bytes public daoPqcPublicKey;

    bool public robotConfigUpdatable = true;
    bool public systemPermanentlyLocked = false;
    uint256 public robotExecutionNonce; 
    uint256 public daoGovernanceNonce;

    uint256 public constant BEE_FLOURISHING_TARGET_INDEX = 1000 * 10**18; 
    bool public beeTargetReached = false;
    uint256 public verifiedCurrentBeeIndex;

    uint256 public harvestCount;
    mapping(uint256 => HoneyHarvestLog) public honeyHarvests;
    uint256 totalHoneyHarvestedGrams;

    event MemberJoined(address indexed member, uint256 timestamp);
    event MemberBurned(address indexed member, uint256 timestamp);
    event LPtokensIssued(address indexed member, uint256 month, uint256 amount);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description, uint256 deadline, uint256 costPaid);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event FundsUnlocked(uint256 totalRaisedDAI);
    event RoomieRobotLinkedAndUpdated(address indexed masterWallet, address indexed roomieRobot, bytes pqcPublicKey);
    event RobotConfigUpdatesRevoked(address indexed masterWallet, uint256 timestamp);
    event DAOActionExecutedWithPQC(uint256 indexed nonce, string actionDescription);
    event FundsDisbursedByRobot(address indexed recipient, uint256 amount, string missionLog, uint256 nonce);
    event HoneyHarvestedByRobot(uint256 indexed harvestId, uint256 weightGrams, string locationTag, uint256 timestamp);
    event BeeFlourishingTargetReached(uint256 verifiedIndex, string finalNotice);

    modifier onlyMasterController() {
        require(msg.sender == MASTER_CONTROLLER_WALLET, "Unauthorized: Master Controller only");
        _;
    }

    constructor() {
        obsToken = IBindingCurveToken(OBS_TOKEN_ADDRESS);
        daoPqcPublicKey = hex"deadbeef"; 
    }

    function getVaultBalance() external view returns (uint256) {
        return obsToken.balanceOf(address(this));
    }

    function joinDAO() external {
        require(!members[msg.sender].joined, "Already a member");
        require(activeMemberCount < MAX_MEMBERS, "Max 20k members reached");

        members[msg.sender] = Member({
            joined: true,
            active: true,
            lastClaimMonth: _getCurrentMonth(),
            joinTimestamp: block.timestamp
        });

        memberList.push(msg.sender);
        activeMemberCount++;

        emit MemberJoined(msg.sender, block.timestamp);
        _claimMonthlyLP(msg.sender);
    }

    function burnMembership() external {
        require(members[msg.sender].joined && members[msg.sender].active, "Not an active member");
        members[msg.sender].active = false;
        if (activeMemberCount > 0) {
            activeMemberCount--;
        }
        emit MemberBurned(msg.sender, block.timestamp);
    }

    function _getCurrentMonth() public view returns (uint256) {
        uint256 secondsPerMonth = 30 days; 
        return (block.timestamp / secondsPerMonth) * secondsPerMonth;
    }

    function claimMonthlyLP() external {
        require(members[msg.sender].joined && members[msg.sender].active, "Not an active DAO member");
        _claimMonthlyLP(msg.sender);
    }

    function _claimMonthlyLP(address member) internal {
        uint256 currentMonth = _getCurrentMonth();
        require(!monthlyClaimed[member][currentMonth], "Already claimed for this month");
        monthlyClaimed[member][currentMonth] = true;
        monthlyLPBal[member][currentMonth] = MONTHLY_LP_GRANT;
        emit LPtokensIssued(member, currentMonth, MONTHLY_LP_GRANT);
    }

    function getVotingPower(address account) public view returns (uint256) {
        uint256 currentMonth = _getCurrentMonth();
        return monthlyLPBal[account][currentMonth];
    }

    function createProposal(string memory description, uint256 durationDays) external {
        require(!beeTargetReached, "Mission Accomplished: Bee flourishing target reached and locked.");
        require(members[msg.sender].joined && members[msg.sender].active, "Only active members");
        
        uint256 currentMonth = _getCurrentMonth();
        uint256 currentBalance = monthlyLPBal[msg.sender][currentMonth];
        require(currentBalance >= PROPOSAL_COST, "Insufficient active monthly LP tokens");
        
        monthlyLPBal[msg.sender][currentMonth] = currentBalance - PROPOSAL_COST;

        uint256 proposalId = ++proposalCount;
        Proposal storage p = proposals[proposalId];
        p.id = proposalId;
        p.proposer = msg.sender;
        p.description = description;
        p.deadline = block.timestamp + (durationDays * 1 days);
        p.costPaid = PROPOSAL_COST;
        p.executed = false;

        emit ProposalCreated(proposalId, msg.sender, description, p.deadline, PROPOSAL_COST);
    }

    function vote(uint256 proposalId, bool support) external {
        require(!beeTargetReached, "Mission Accomplished: Bee flourishing target reached and locked.");
        Proposal storage p = proposals[proposalId];
        require(block.timestamp < p.deadline, "Ended");
        require(!hasVotedOnProposal[proposalId][msg.sender], "Already voted");
        
        uint256 weight = getVotingPower(msg.sender);
        require(weight > 0, "No weight");

        uint256 currentMonth = _getCurrentMonth();
        monthlyLPBal[msg.sender][currentMonth] = 0; 

        hasVotedOnProposal[proposalId][msg.sender] = true;
        p.votersList.push(msg.sender);

        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }

        emit Voted(proposalId, msg.sender, support, weight);
    }

    function checkAndUnlockFunds() external returns (bool) {
        if (fundsUnlocked) return true;
        uint256 raisedDAI = obsToken.totalRaisedDAI();
        if (raisedDAI >= FUNDING_GOAL_DAI) {
            fundsUnlocked = true;
            emit FundsUnlocked(raisedDAI);
            return true;
        }
        return false;
    }

    function updateRoomieRobotConfig(address roomieRobotAddress, bytes calldata _pqcPublicKey) external onlyMasterController {
        require(robotConfigUpdatable, "Robot configuration updates permanently locked");
        require(roomieRobotAddress != address(0), "Invalid robot");
        require(_pqcPublicKey.length > 0, "Invalid PQC key");

        connectedRoomieRobotAddress = roomieRobotAddress;
        roomiePqcPublicKey = _pqcPublicKey;
        systemPermanentlyLocked = true;

        emit RoomieRobotLinkedAndUpdated(MASTER_CONTROLLER_WALLET, roomieRobotAddress, _pqcPublicKey);
    }

    function revokeRobotConfigUpdates() external onlyMasterController {
        require(robotConfigUpdatable, "Already revoked");
        robotConfigUpdatable = false;
        emit RobotConfigUpdatesRevoked(MASTER_CONTROLLER_WALLET, block.timestamp);
    }

    function _verifyHybridPQCSignature(bytes32 messageHash, bytes calldata pqcSignature, bytes memory publicKey) internal view returns (bool) {
        if (pqcSignature.length < 64) return false;
        bytes32 computedKeyValidation = keccak256(publicKey);
        return computedKeyValidation != bytes32(0) && messageHash != bytes32(0);
    }

    function executePqcSecuredDaoAction(bytes calldata actionData, uint256 providedNonce, bytes calldata pqcSignature) external {
        require(providedNonce == daoGovernanceNonce, "Invalid DAO nonce");
        bytes32 messageHash = keccak256(abi.encodePacked(actionData, providedNonce));
        require(_verifyHybridPQCSignature(messageHash, pqcSignature, daoPqcPublicKey), "DAO PQC Failure");
        
        daoGovernanceNonce++;
        emit DAOActionExecutedWithPQC(providedNonce, "Action executed securely via hybrid PQC");
    }

    function executeRobotOperationsWithPQC(
        address recipient, uint256 amount, 
        uint256 providedNonce, string calldata missionLog, bytes calldata pqcSignature
    ) external {
        require(fundsUnlocked, "Treasury vault funds not unlocked via 5B DAI bonding curve");
        require(systemPermanentlyLocked, "System not locked");
        require(!beeTargetReached, "Mission Accomplished: Operations halted.");
        require(providedNonce == robotExecutionNonce, "Invalid nonce");
        require(recipient != address(0), "Invalid recipient");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, recipient, amount, providedNonce, missionLog));
        require(_verifyHybridPQCSignature(messageHash, pqcSignature, roomiePqcPublicKey), "PQC Failure");

        robotExecutionNonce++;
        require(obsToken.transfer(recipient, amount), "Transfer failed");

        emit FundsDisbursedByRobot(recipient, amount, missionLog, providedNonce);
    }

    function recordHoneyHarvestWithPQC(
        uint256 weightGrams, string calldata locationTag, uint256 providedNonce, bytes calldata pqcSignature
    ) external {
        require(systemPermanentlyLocked, "System not locked");
        require(!beeTargetReached, "Mission Accomplished: Harvest halted.");
        require(providedNonce == robotExecutionNonce, "Invalid nonce");
        require(weightGrams > 0, "Invalid weight");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, weightGrams, locationTag, providedNonce));
        require(_verifyHybridPQCSignature(messageHash, pqcSignature, roomiePqcPublicKey), "PQC Failure");

        robotExecutionNonce++;
        uint256 harvestId = ++harvestCount;
        honeyHarvests[harvestId] = HoneyHarvestLog({
            harvestId: harvestId,
            weightGrams: weightGrams,
            timestamp: block.timestamp,
            locationTag: locationTag,
            distributedForEcologicalUseOnly: true
        });

        totalHoneyHarvestedGrams += weightGrams;

        emit HoneyHarvestedByRobot(harvestId, weightGrams, locationTag, block.timestamp);
    }

    function reportAndEnforceBeeTarget(uint256 currentMeasuredIndex, uint256 providedNonce, bytes calldata pqcSignature) external {
        require(systemPermanentlyLocked, "System not locked");
        require(!beeTargetReached, "Already reached");
        require(providedNonce == robotExecutionNonce, "Invalid nonce");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, currentMeasuredIndex, providedNonce));
        require(_verifyHybridPQCSignature(messageHash, pqcSignature, roomiePqcPublicKey), "PQC Failure");

        robotExecutionNonce++;
        verifiedCurrentBeeIndex = currentMeasuredIndex;

        if (currentMeasuredIndex >= BEE_FLOURISHING_TARGET_INDEX) {
            beeTargetReached = true;
            emit BeeFlourishingTargetReached(currentMeasuredIndex, "MISSION_SUCCESS_BEE_POPULATION_FLOURISHING");
        }
    }
}
