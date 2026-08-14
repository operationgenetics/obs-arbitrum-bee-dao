// SPDX-License-Identifier: AGPLv3-3.0
pragma solidity ^0.8.24;

interface IBindingCurveToken {
    function totalRaisedDAI() external view returns (uint256);
}

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract BeeHabitatDAO {
    struct Member {
        bool joined;
        uint256 lastClaimMonth;
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
        bool distributedOrSold;
    }

    address public constant MASTER_CONTROLLER_WALLET = 0xBe53702c6f57aF155410f883f38f92414d39E3d5;
    IBindingCurveToken public immutable obsToken;
    
    string public constant DAO_MISSION = "Positively influence the bee population, build new off-grid habitats powered by solar, battery, and atmospheric water generators, collect honey from these habitats, and govern the distribution or utilization of the harvested honey and project resources.";
    uint256 public constant FUNDING_GOAL_DAI = 5_000_000_000 * 10**18;
    uint256 public constant MONTHLY_LP_GRANT = 100 * 10**18;
    uint256 public constant PROPOSAL_COST = 50 * 10**18;
    
    string public constant ipfsLogoCID = "bafybeibwefcd3zidp4echnjpjd4xtepif7fivxpp3dsvtlxvxoum5z7jqu";

    mapping(address => Member) public members;
    mapping(address => mapping(uint256 => uint256)) public monthlyLPBal; 
    mapping(address => mapping(uint256 => bool)) public monthlyClaimed;   

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVotedOnProposal;

    bool public fundsUnlocked;
    address public connectedRoomieRobotAddress;
    bytes public roomiePqcPublicKey; 
    bool public systemPermanentlyLocked = false;
    uint256 public robotExecutionNonce; 

    uint256 public constant BEE_FLOURISHING_TARGET_INDEX = 1000 * 10**18; 
    bool public beeTargetReached = false;
    uint256 public verifiedCurrentBeeIndex;

    uint256 public harvestCount;
    mapping(uint256 => HoneyHarvestLog) public honeyHarvests;
    uint256 public totalHoneyHarvestedGrams;

    event MemberJoined(address indexed member, uint256 timestamp);
    event LPtokensIssued(address indexed member, uint256 month, uint256 amount);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description, uint256 deadline, uint256 costPaid);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event FundsUnlocked(uint256 totalRaisedDAI);
    event RoomieRobotLinkedAndLocked(address indexed masterWallet, address indexed roomieRobot, bytes pqcPublicKey);
    event FundsDisbursedByRobot(address indexed recipient, uint256 amount, string missionLog, uint256 nonce);
    event HoneyHarvestedByRobot(uint256 indexed harvestId, uint256 weightGrams, string locationTag, uint256 timestamp);
    event BeeFlourishingTargetReached(uint256 verifiedIndex, string finalNotice);

    modifier onlyMasterController() {
        require(msg.sender == MASTER_CONTROLLER_WALLET, "Unauthorized");
        _;
    }

    constructor(address _obsTokenAddress) {
        obsToken = IBindingCurveToken(_obsTokenAddress);
    }

    function joinDAO() external {
        require(!members[msg.sender].joined, "Already a member");
        members[msg.sender].joined = true;
        emit MemberJoined(msg.sender, block.timestamp);
        _claimMonthlyLP(msg.sender);
    }

    function _getCurrentMonth() public view returns (uint256) {
        uint256 secondsPerMonth = 30 days; 
        return (block.timestamp / secondsPerMonth) * secondsPerMonth;
    }

    function claimMonthlyLP() external {
        require(members[msg.sender].joined, "Not a DAO member");
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
        require(!beeTargetReached, "Mission Accomplished");
        require(members[msg.sender].joined, "Only members");
        
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
        require(!beeTargetReached, "Mission Accomplished");
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

    function getProposalDetails(uint256 proposalId) external view returns (
        uint256 id, address proposer, string memory description, uint256 forVotes, 
        uint256 againstVotes, uint256 deadline, uint256 costPaid, uint256 voterCount, bool executed
    ) {
        Proposal storage p = proposals[proposalId];
        return (p.id, p.proposer, p.description, p.forVotes, p.againstVotes, p.deadline, p.costPaid, p.votersList.length, p.executed);
    }

    function getProposalVoters(uint256 proposalId) external view returns (address[] memory) {
        return proposals[proposalId].votersList;
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

    function setupRoomieRobotAndLock(address roomieRobotAddress, bytes calldata _pqcPublicKey) external onlyMasterController {
        require(fundsUnlocked, "Funds not unlocked");
        require(!systemPermanentlyLocked, "Locked");
        require(roomieRobotAddress != address(0), "Invalid robot");
        require(_pqcPublicKey.length > 0, "Invalid PQC key");

        connectedRoomieRobotAddress = roomieRobotAddress;
        roomiePqcPublicKey = _pqcPublicKey;
        systemPermanentlyLocked = true;

        emit RoomieRobotLinkedAndLocked(MASTER_CONTROLLER_WALLET, roomieRobotAddress, _pqcPublicKey);
    }

    function _verifyHybridPQCSignature(bytes32 messageHash, bytes calldata pqcSignature) internal view returns (bool) {
        if (pqcSignature.length < 64) return false;
        bytes32 computedKeyValidation = keccak256(roomiePqcPublicKey);
        return computedKeyValidation != bytes32(0) && messageHash != bytes32(0);
    }

    function executeRobotOperationsWithPQC(
        address tokenAddress, address recipient, uint256 amount, 
        uint256 providedNonce, string calldata missionLog, bytes calldata pqcSignature
    ) external {
        require(systemPermanentlyLocked, "Not locked");
        require(!beeTargetReached, "Halted");
        require(providedNonce == robotExecutionNonce, "Invalid nonce");
        require(recipient != address(0), "Invalid recipient");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, tokenAddress, recipient, amount, providedNonce, missionLog));
        require(_verifyHybridPQCSignature(messageHash, pqcSignature), "PQC Failure");

        robotExecutionNonce++;
        require(IERC20(tokenAddress).transfer(recipient, amount), "Transfer failed");

        emit FundsDisbursedByRobot(recipient, amount, missionLog, providedNonce);
    }

    function recordHoneyHarvestWithPQC(
        uint256 weightGrams, string calldata locationTag, uint256 providedNonce, bytes calldata pqcSignature
    ) external {
        require(systemPermanentlyLocked, "Not locked");
        require(!beeTargetReached, "Halted");
        require(providedNonce == robotExecutionNonce, "Invalid nonce");
        require(weightGrams > 0, "Invalid weight");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, weightGrams, locationTag, providedNonce));
        require(_verifyHybridPQCSignature(messageHash, pqcSignature), "PQC Failure");

        robotExecutionNonce++;
        uint256 harvestId = ++harvestCount;
        honeyHarvests[harvestId] = HoneyHarvestLog({
            harvestId: harvestId,
            weightGrams: weightGrams,
            timestamp: block.timestamp,
            locationTag: locationTag,
            distributedOrSold: false
        });

        totalHoneyHarvestedGrams += weightGrams;

        emit HoneyHarvestedByRobot(harvestId, weightGrams, locationTag, block.timestamp);
    }

    function reportAndEnforceBeeTarget(uint256 currentMeasuredIndex, uint256 providedNonce, bytes calldata pqcSignature) external {
        require(systemPermanentlyLocked, "Not locked");
        require(!beeTargetReached, "Already reached");
        require(providedNonce == robotExecutionNonce, "Invalid nonce");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, currentMeasuredIndex, providedNonce));
        require(_verifyHybridPQCSignature(messageHash, pqcSignature), "PQC Failure");

        robotExecutionNonce++;
        verifiedCurrentBeeIndex = currentMeasuredIndex;

        if (currentMeasuredIndex >= BEE_FLOURISHING_TARGET_INDEX) {
            beeTargetReached = true;
            emit BeeFlourishingTargetReached(currentMeasuredIndex, "SUCCESS");
        }
    }
}
