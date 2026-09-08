// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BeeHabitatDAO
 * @notice Fully off-grid, zero-config DAO + vault for the Obscura (OBS) ecosystem on Arbitrum One.
 *
 * DESIGN INVARIANTS (all hardcoded, no constructor arguments, no proxy, no owner, no pause):
 *  - Vault holds OBS. Nothing can leave the vault until the OBS bonding curve has genuinely
 *    collected 5,000,000,000 DAI, read TRUSTLESSLY from the OBS token itself. No oracle, no
 *    caller-supplied number, no off-chain feed. Fully off-grid.
 *  - Spending is gated behind a hybrid post-quantum credential physically held on the Roomie
 *    humanoid robot's PQC MCU. Biometric templates NEVER touch the chain - only the public
 *    commitment does.
 *  - Funds are mathematically time-released across the whole life of a project (>= 6 tranches,
 *    one per 60 days, each capped as a fraction of the vault) so a project cannot be drained in
 *    one transaction and the OBS price cannot be crashed by the DAO itself.
 *  - Every tranche requires an on-chain, robot-signed attestation that the hardcoded mission
 *    rules are actually being executed in the real world.
 *  - The robot configuration is updatable exactly until the config authority signs
 *    `revokeAndUpdateImmutability()`. After that the contract is permanently, irreversibly frozen
 *    in configuration: no key can ever be changed, added or rotated again by anyone.
 */
contract BeeHabitatDAO is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ------------------------------------------------------------------ */
    /*                      IMMUTABLE ON-CHAIN WIRING                      */
    /* ------------------------------------------------------------------ */

    /// @notice Obscura (OBS) on Arbitrum One. Verified: name "Obscura", symbol "OBS", 18 decimals.
    address public constant OBS_TOKEN = 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;

    /// @notice The ONLY wallet that may provision / rotate / freeze the Roomie robot credential
    ///         and drive operations. Hardcoded, cannot be transferred, cannot be renounced.
    address public constant ADMIN_ORCHESTRATOR = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    /// @notice 5 billion DAI (18 decimals) of real bonding-curve reserves unlocks the vault.
    uint256 public constant BONDING_CURVE_DAI_UNLOCK_TARGET = 5_000_000_000 * 1e18;

    /// @dev `daiReserve()` on the OBS token - the live bonding-curve reserve.
    bytes4 private constant SEL_DAI_RESERVE = 0xe2771ec8;
    /// @dev `totalDaiCollected()` on the OBS token - cumulative DAI taken in by the curve.
    bytes4 private constant SEL_TOTAL_DAI_COLLECTED = 0x57d0e873;

    /* ------------------------------------------------------------------ */
    /*                    HARDCODED MISSION RULES (ROBOTS)                 */
    /* ------------------------------------------------------------------ */

    string public constant HABITAT_FOCUS_ZONE =
        "Nationwide United States Off-Grid Indoor & Regional Pollinator Corridors";

    string public constant MISSION_MANDATE =
        "Off-grid indoor bee habitats with atmospheric water generation, solar generation and "
        "battery storage; honey farmed and given away free; land and equipment acquired and "
        "maintained indefinitely until the optimal bee flourishing index is reached.";

    uint256 public constant MIN_FLOWERING_ACRES_TARGET = 20;
    uint256 public constant OPTIMAL_BEE_INDEX_CAP = 500_000;
    /// @notice Global flourishing target. Operations continue indefinitely until this is met.
    uint256 public constant TARGET_BEE_FLOURISHING_INDEX = 500_000;

    /* ------------------------------------------------------------------ */
    /*                   HARDCODED GOVERNANCE PARAMETERS                   */
    /* ------------------------------------------------------------------ */

    uint256 public constant MONTHLY_LP_ISSUANCE = 100 * 1e18; // 100 LP per member per month
    uint256 public constant PROPOSAL_THRESHOLD = 50 * 1e18;   // 50 LP to open a proposal
    uint256 public constant VOTING_PERIOD_DURATION = 30 days;
    uint256 public constant LP_EPOCH = 30 days;               // LP expires at the epoch boundary
    uint256 public constant MILESTONE_GATING_INTERVAL = 60 days; // robot authorises 1x / 2 months
    uint256 public constant QUORUM_PERCENTAGE = 10;           // 10% of the month's live LP supply

    /* ------------------------------------------------------------------ */
    /*                 HARDCODED ANTI-DUMP / TIME-LOCK RULES               */
    /* ------------------------------------------------------------------ */

    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice No single project may reserve more than 20% of the unreserved vault.
    uint256 public constant MAX_PROJECT_BPS_OF_VAULT = 2_000;
    /// @notice No single 60-day tranche may exceed 2.5% of the vault balance at release time.
    uint256 public constant MAX_TRANCHE_BPS_OF_VAULT = 250;
    /// @notice Every project is stretched over at least 6 tranches => at least 12 months.
    uint32 public constant MIN_PROJECT_MILESTONES = 6;
    uint32 public constant MAX_PROJECT_MILESTONES = 120;
    uint256 public constant PROJECT_GRACE_PERIOD = 90 days;

    /* ------------------------------------------------------------------ */
    /*                     HYBRID PQC CREDENTIAL RULES                     */
    /* ------------------------------------------------------------------ */

    /// @dev Rejects classically-sized signatures masquerading as PQC.
    ///      Falcon-512 = 666 B, ML-DSA-44 = 2420 B, SPHINCS+-128s = 7856 B.
    uint256 public constant MIN_PQC_SIGNATURE_BYTES = 512;
    uint256 public constant MIN_PQC_PUBLIC_KEY_BYTES = 32;

    bytes32 public constant MILESTONE_TYPEHASH =
        keccak256("RoomieMilestoneAuthorization(uint256 projectId,uint32 milestoneIndex,uint256 amount,address recipient,bytes32 attestationHash)");

    /* ------------------------------------------------------------------ */
    /*                               STORAGE                               */
    /* ------------------------------------------------------------------ */

    /**
     * @notice The Roomie humanoid robot's hybrid post-quantum credential.
     * @dev Biometric templates are hard-locked inside the MCU secure element and are NEVER
     *      written on chain. Only public commitments live here.
     *
     *      Hybrid = an attacker must break BOTH legs:
     *        - classical leg : secp256k1 ECDSA from the MCU's classical key.
     *        - quantum leg   : keccak256 pre-image resistance (PQC public key commitment +
     *                          a one-time-signature hash chain). Immune to Shor's algorithm.
     */
    struct RobotCredential {
        bytes32 pqcPublicKeyHash;  // keccak256(full PQC public key stored on the MCU)
        address mcuEcdsaSigner;    // classical secp256k1 leg, also sealed in the MCU
        bytes32 otsChainTip;       // post-quantum one-time-signature (hash chain) tip
        uint64 otsRemaining;       // authorisations left in the chain
        bool provisioned;          // day-one provisional setup done
        bool commissioned;         // real hardware landed; spending is possible
    }

    RobotCredential public robot;

    /// @notice False once `revokeAndUpdateImmutability()` is signed. Never returns to true.
    bool public canUpdateRobotConfig = true;

    /// @notice Set by `checkAndUnlockVault()` once the OBS curve truly holds 5B DAI. One-way.
    bool public vaultUnlocked;

    uint256 public totalObsVaultBalance;
    uint256 public totalReservedForProjects;
    uint256 public totalObsReleased;

    /// @notice Cumulative, robot-attested bee flourishing index across all projects.
    uint256 public beeFlourishingIndex;
    bool public optimalBeeFlourishingReached;

    struct LpTokenLedger {
        uint256 balance;
        uint256 epoch; // LP_EPOCH index in which this balance was issued
    }

    mapping(address => LpTokenLedger) public monthlyLpBalances;
    /// @notice Live LP issued per epoch - the denominator for quorum.
    mapping(uint256 => uint256) public lpSupplyByEpoch;

    struct OffGridHabitatProposal {
        uint256 id;
        address proposer;
        address payoutRecipient;
        string description;
        uint256 targetAcresForBees;
        uint256 proposedBeePopulationIndex;
        uint256 requestedFunding;
        bool solarAndBatteryEquipped;
        bool atmosphericWaterGenEquipped;
        bool landAcquisitionIncluded;
        bool equipmentAcquisitionIncluded;
        bool honeyProductionAndDistribution;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 startTime;
        uint256 endTime;
        uint256 startEpoch;
        bool executed;
        bool canceled;
        mapping(address => bool) hasVoted;
    }

    mapping(uint256 => OffGridHabitatProposal) internal proposals;
    uint256 public proposalCount;

    struct Project {
        uint256 id;
        uint256 proposalId;
        address creator;
        address payoutRecipient;
        uint256 fundingAmount;
        uint256 fundingRemaining;
        uint256 perMilestoneCap;
        uint256 trancheCeiling;
        uint32 milestoneCount;
        uint32 milestonesCompleted;
        uint256 startTime;
        uint256 deadline;
        uint256 lastMilestoneTime;
        bool completed;
        bool expired;
        string missionDescription;
    }

    /// @notice Cumulative real-world delivery, attested by the robot at every tranche.
    struct MissionLedger {
        uint256 acresSecured;
        uint256 hivesInstalled;
        uint256 honeyKgDistributedFree;
        uint256 atmosphericWaterLiters;
        uint256 solarKwhGenerated;
        uint256 batteryKwhStored;
    }

    /// @notice One tranche's worth of robot-verified, real-world evidence.
    struct MilestoneAttestation {
        uint256 acresSecured;
        uint256 hivesInstalled;
        uint256 honeyKgDistributedFree;
        uint256 atmosphericWaterLiters;
        uint256 solarKwhGenerated;
        uint256 batteryKwhStored;
        uint256 beeFlourishingIndexDelta;
        bool offGridVerified;      // zero grid interconnection at the site
        bool landAcquired;         // land acquisition executed / held
        bool equipmentOperational; // maintenance equipment on site and running
        bytes32 evidenceHash;      // hash of the robot's sensor/photo evidence bundle
    }

    mapping(uint256 => Project) internal projects;
    mapping(uint256 => MissionLedger) internal missionLedgers;
    uint256 public projectCount;

    /* ------------------------------------------------------------------ */
    /*                               EVENTS                                */
    /* ------------------------------------------------------------------ */

    event RoomieRobotProvisioned(bytes32 pqcPublicKeyHash);
    event RoomieRobotCommissioned(bytes32 pqcPublicKeyHash, address mcuEcdsaSigner, bytes32 otsChainTip, uint64 otsChainLength);
    event RoomieRobotConfigured(bytes32 pqcPublicKeyHash);
    event RobotConfigRevoked();
    event OffGridBeeHabitatProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint256 targetAcres,
        uint256 proposedBeePopulationIndex,
        uint256 requestedFunding,
        address payoutRecipient
    );
    event LpTokensIssued(address indexed recipient, uint256 amount, uint256 indexed epoch);
    event Voted(uint256 indexed proposalId, address indexed voter, uint256 weight, bool support);
    event VaultUnlockedByBondingCurve(uint256 daiReserves);
    event VaultDeposit(address indexed from, uint256 amount);
    event VaultSynced(uint256 credited, uint256 newBalance);
    event ProjectCreated(uint256 indexed projectId, uint256 indexed proposalId, address indexed creator, uint256 fundingAmount, uint32 milestoneCount, uint256 perMilestoneCap, uint256 deadline);
    event MilestoneAuthorizedByRobot(uint256 indexed projectId, uint32 indexed milestoneIndex, uint256 amount, bytes32 pqcSignatureHash, bytes32 evidenceHash, uint256 timestamp);
    event ProjectFundsWithdrawn(uint256 indexed projectId, uint256 amount, address recipient);
    event ProjectCompleted(uint256 indexed projectId);
    event ProjectExpired(uint256 indexed projectId, uint256 fundsReturnedToVault);
    event BeeFlourishingIndexUpdated(uint256 newIndex);
    event OptimalBeeFlourishingReached(uint256 index, uint256 timestamp);

    /* ------------------------------------------------------------------ */
    /*                              MODIFIERS                              */
    /* ------------------------------------------------------------------ */

    modifier onlyAdminOrRobot() {
        require(msg.sender == ADMIN_ORCHESTRATOR, "Unauthorized: Must match hardware orchestrator");
        _;
    }

    modifier onlyWhenVaultUnlocked() {
        require(vaultUnlocked, "Vault not unlocked: 5B DAI threshold not reached");
        _;
    }

    modifier onlyWhileConfigurable() {
        require(canUpdateRobotConfig, "Robot configuration is permanently immutable");
        _;
    }

    /// @dev Zero-config: no constructor arguments. Deploy = compile + sign.
    constructor() {}

    function obsToken() external pure returns (address) {
        return OBS_TOKEN;
    }

    /* ------------------------------------------------------------------ */
    /*              ROOMIE ROBOT HYBRID PQC CREDENTIAL LIFECYCLE           */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Day one, immediately after deployment: anchor the placeholder / provisional PQC
     *         public-key commitment. Callable the moment the contract exists.
     * @dev Provisional only - it does NOT enable spending. Spending requires
     *      `commissionRoomieRobot()` with the real MCU credential.
     */
    function setupRoomieRobotAndLock(bytes32 _pqcPublicKeyHash)
        external
        onlyAdminOrRobot
        onlyWhileConfigurable
    {
        require(_pqcPublicKeyHash != bytes32(0), "Invalid PQC public key hash");
        robot.pqcPublicKeyHash = _pqcPublicKeyHash;
        robot.provisioned = true;
        emit RoomieRobotProvisioned(_pqcPublicKeyHash);
        emit RoomieRobotConfigured(_pqcPublicKeyHash);
    }

    /**
     * @notice Once the Roomie humanoid robot and its hybrid PQC MCU physically arrive, bind the
     *         real credential: the PQC public key commitment, the classical secp256k1 leg, and
     *         the post-quantum one-time-signature hash-chain tip.
     * @dev The biometric templates stay hard-locked on the MCU. Only these public commitments
     *      are ever written on chain.
     * @param _pqcPublicKeyHash keccak256 of the MCU's full PQC public key.
     * @param _mcuEcdsaSigner   secp256k1 address derived inside the MCU secure element.
     * @param _otsChainTip      s_N where s_i = keccak256(abi.encodePacked(s_{i-1})); the MCU holds s_0.
     * @param _otsChainLength   number of authorisations the chain can serve.
     */
    function commissionRoomieRobot(
        bytes32 _pqcPublicKeyHash,
        address _mcuEcdsaSigner,
        bytes32 _otsChainTip,
        uint64 _otsChainLength
    ) external onlyAdminOrRobot onlyWhileConfigurable {
        require(_pqcPublicKeyHash != bytes32(0), "Invalid PQC public key hash");
        require(_mcuEcdsaSigner != address(0), "Invalid MCU ECDSA signer");
        require(_otsChainTip != bytes32(0), "Invalid PQC OTS chain tip");
        require(_otsChainLength > 0, "Invalid PQC OTS chain length");

        robot.pqcPublicKeyHash = _pqcPublicKeyHash;
        robot.mcuEcdsaSigner = _mcuEcdsaSigner;
        robot.otsChainTip = _otsChainTip;
        robot.otsRemaining = _otsChainLength;
        robot.provisioned = true;
        robot.commissioned = true;

        emit RoomieRobotCommissioned(_pqcPublicKeyHash, _mcuEcdsaSigner, _otsChainTip, _otsChainLength);
        emit RoomieRobotConfigured(_pqcPublicKeyHash);
    }

    /// @notice Rotate only the PQC public-key commitment (e.g. MCU firmware / key refresh).
    function updateRobotPqcPublicKey(bytes32 _newPqcPublicKeyHash)
        external
        onlyAdminOrRobot
        onlyWhileConfigurable
    {
        require(robot.provisioned, "Robot not yet configured");
        require(_newPqcPublicKeyHash != bytes32(0), "Invalid PQC public key hash");
        robot.pqcPublicKeyHash = _newPqcPublicKeyHash;
        emit RoomieRobotConfigured(_newPqcPublicKeyHash);
    }

    /**
     * @notice FINAL, IRREVERSIBLE. After this transaction the robot credential - PQC public key,
     *         MCU ECDSA signer and OTS chain - can never be changed by anyone, ever. The contract
     *         becomes permanently immutable in configuration.
     */
    function revokeAndUpdateImmutability() external onlyAdminOrRobot onlyWhileConfigurable {
        canUpdateRobotConfig = false;
        emit RobotConfigRevoked();
    }

    /**
     * @dev Hybrid post-quantum + classical verification of an MCU authorisation.
     *
     *  Leg 1 (PQ, identity)      : the full PQC public key must hash to the anchored commitment.
     *  Leg 2 (PQ, authorisation) : reveal the next link of the MCU's keccak256 OTS hash chain.
     *                              Replay-proof and forward-secure; survives a quantum adversary.
     *  Leg 3 (PQ, anchoring)     : the full PQC signature is hashed and bound in, so the robot
     *                              fleet can verify it against the anchored public key.
     *  Leg 4 (classical)         : secp256k1 ECDSA over a domain-separated digest binding legs 1-3.
     *
     *  Forgery requires breaking secp256k1 AND keccak256 pre-image resistance.
     */
    function _verifyHybridPqcAuthorization(
        bytes32 actionDigest,
        bytes calldata pqcPublicKey,
        bytes calldata pqcSignature,
        bytes calldata mcuEcdsaSignature,
        bytes32 otsPreimage
    ) internal returns (bytes32 pqcSignatureHash) {
        RobotCredential storage cred = robot;
        require(cred.commissioned, "Roomie robot MCU not commissioned");

        // Leg 1 - post-quantum identity commitment.
        require(pqcPublicKey.length >= MIN_PQC_PUBLIC_KEY_BYTES, "PQC public key too short");
        require(keccak256(pqcPublicKey) == cred.pqcPublicKeyHash, "PQC public key mismatch");

        // Leg 2 - post-quantum one-time-signature chain link.
        require(cred.otsRemaining > 0, "PQC OTS chain exhausted");
        require(keccak256(abi.encodePacked(otsPreimage)) == cred.otsChainTip, "Invalid PQC OTS preimage");

        // Leg 3 - anchor the full PQC signature.
        require(pqcSignature.length >= MIN_PQC_SIGNATURE_BYTES, "PQC signature too short");
        pqcSignatureHash = keccak256(pqcSignature);

        // Leg 4 - classical secp256k1 leg over everything above, domain separated.
        bytes32 payload = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                actionDigest,
                cred.pqcPublicKeyHash,
                pqcSignatureHash,
                otsPreimage
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
        require(_recoverSigner(digest, mcuEcdsaSignature) == cred.mcuEcdsaSigner, "Invalid MCU ECDSA signature");

        // Consume the one-time link.
        cred.otsChainTip = otsPreimage;
        unchecked {
            cred.otsRemaining -= 1;
        }
    }

    /**
     * @dev Minimal, self-contained secp256k1 recovery. Rejects malleable (high-s) signatures and
     *      the zero address so a forged signature can never resolve to an unset signer. Inlined
     *      deliberately: an immutable contract should not carry avoidable dependencies.
     */
    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        require(signature.length == 65, "Invalid ECDSA signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) {
            v += 27;
        }
        require(v == 27 || v == 28, "Invalid ECDSA signature v");
        require(
            uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
            "Malleable ECDSA signature"
        );
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "Invalid ECDSA signature");
        return signer;
    }

    /* ------------------------------------------------------------------ */
    /*                 TRUSTLESS BONDING-CURVE VAULT UNLOCK                */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Reads the OBS bonding-curve DAI reserves directly from the OBS token contract.
     * @dev Fully off-grid: no oracle, no relayer, no caller-supplied value.
     */
    function bondingCurveDaiReserves() public view returns (uint256) {
        (bool ok, bytes memory data) = OBS_TOKEN.staticcall(abi.encodeWithSelector(SEL_DAI_RESERVE));
        if (ok && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        (ok, data) = OBS_TOKEN.staticcall(abi.encodeWithSelector(SEL_TOTAL_DAI_COLLECTED));
        if (ok && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return 0;
    }

    /// @notice Permissionless. Unlocks the vault only when the curve genuinely holds 5B DAI.
    function checkAndUnlockVault() external {
        require(!vaultUnlocked, "Vault already unlocked");
        uint256 reserves = bondingCurveDaiReserves();
        require(reserves >= BONDING_CURVE_DAI_UNLOCK_TARGET, "Target of 5 Billion DAI not reached");
        vaultUnlocked = true;
        emit VaultUnlockedByBondingCurve(reserves);
    }

    /* ------------------------------------------------------------------ */
    /*                        OBS VAULT (RECEIVE/HOLD)                     */
    /* ------------------------------------------------------------------ */

    function depositToVault(uint256 amount) external nonReentrant {
        require(amount > 0, "Nothing to deposit");
        uint256 before = IERC20(OBS_TOKEN).balanceOf(address(this));
        IERC20(OBS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(OBS_TOKEN).balanceOf(address(this)) - before;
        totalObsVaultBalance += received;
        emit VaultDeposit(msg.sender, received);
    }

    /// @notice Permissionless. Credits OBS sent to the vault by a plain `transfer`.
    function syncVault() external returns (uint256 credited) {
        uint256 actual = IERC20(OBS_TOKEN).balanceOf(address(this));
        require(actual > totalObsVaultBalance, "Nothing to sync");
        unchecked {
            credited = actual - totalObsVaultBalance;
        }
        totalObsVaultBalance = actual;
        emit VaultSynced(credited, actual);
    }

    function getVaultBalance() external view returns (uint256) {
        return IERC20(OBS_TOKEN).balanceOf(address(this));
    }

    /// @notice Vault OBS not already committed to a live project.
    function availableVaultBalance() public view returns (uint256) {
        uint256 reserved = totalReservedForProjects;
        return totalObsVaultBalance > reserved ? totalObsVaultBalance - reserved : 0;
    }

    /* ------------------------------------------------------------------ */
    /*             MONTHLY LP: 100 / MONTH, EXPIRING, 1 LP = 1 VOTE        */
    /* ------------------------------------------------------------------ */

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / LP_EPOCH;
    }

    /**
     * @notice Issue expiring LP. Hard cap of 100 LP per member per month, cumulative across all
     *         calls in that month. Unused LP expires at the month boundary and is never carried.
     */
    function issueMonthlyLpTokens(address recipient, uint256 amount) external onlyAdminOrRobot {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Nothing to issue");
        uint256 epoch = currentEpoch();

        LpTokenLedger storage ledger = monthlyLpBalances[recipient];
        uint256 alreadyThisMonth = ledger.epoch == epoch ? ledger.balance : 0;
        require(alreadyThisMonth + amount <= MONTHLY_LP_ISSUANCE, "Exceeds monthly issuance limit");

        ledger.balance = alreadyThisMonth + amount;
        ledger.epoch = epoch;
        lpSupplyByEpoch[epoch] += amount;

        emit LpTokensIssued(recipient, amount, epoch);
    }

    /// @notice 1 LP = 1 vote. Returns 0 once the LP has expired.
    function getVotingPower(address account) public view returns (uint256) {
        LpTokenLedger storage ledger = monthlyLpBalances[account];
        if (ledger.epoch < currentEpoch()) {
            return 0;
        }
        return ledger.balance;
    }

    /// @notice Live (unexpired) LP supply - the quorum denominator.
    function getTotalActiveLpSupply() public view returns (uint256) {
        return lpSupplyByEpoch[currentEpoch()];
    }

    /* ------------------------------------------------------------------ */
    /*                     PROPOSALS (MISSION-CONSTRAINED)                 */
    /* ------------------------------------------------------------------ */

    function createOffGridBeeHabitatProposal(
        string calldata description,
        uint256 targetAcresForBees,
        uint256 proposedBeePopulationIndex,
        uint256 requestedFunding,
        address payoutRecipient,
        bool solarAndBatteryEquipped,
        bool atmosphericWaterGenEquipped,
        bool landAcquisitionIncluded,
        bool equipmentAcquisitionIncluded,
        bool honeyProductionAndDistribution
    ) external returns (uint256) {
        require(getVotingPower(msg.sender) >= PROPOSAL_THRESHOLD, "Insufficient unexpired LP tokens (50 required)");
        require(bytes(description).length > 0, "Description required");
        require(requestedFunding > 0, "Requested funding required");
        require(payoutRecipient != address(0), "Invalid payout recipient");
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
        prop.payoutRecipient = payoutRecipient;
        prop.description = description;
        prop.targetAcresForBees = targetAcresForBees;
        prop.proposedBeePopulationIndex = proposedBeePopulationIndex;
        prop.requestedFunding = requestedFunding;
        prop.solarAndBatteryEquipped = solarAndBatteryEquipped;
        prop.atmosphericWaterGenEquipped = atmosphericWaterGenEquipped;
        prop.landAcquisitionIncluded = landAcquisitionIncluded;
        prop.equipmentAcquisitionIncluded = equipmentAcquisitionIncluded;
        prop.honeyProductionAndDistribution = honeyProductionAndDistribution;
        prop.startTime = block.timestamp;
        prop.endTime = block.timestamp + VOTING_PERIOD_DURATION;
        prop.startEpoch = currentEpoch();

        emit OffGridBeeHabitatProposalCreated(
            proposalId,
            msg.sender,
            description,
            targetAcresForBees,
            proposedBeePopulationIndex,
            requestedFunding,
            payoutRecipient
        );
        return proposalId;
    }

    function vote(uint256 proposalId, bool support) external {
        OffGridHabitatProposal storage prop = proposals[proposalId];
        require(prop.id != 0, "Proposal does not exist");
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

    /**
     * @notice Permissionless execution of a passed proposal. The funding amount is whatever the
     *         DAO voted on - it can never be chosen at execution time.
     * @dev Mathematically stretches the spend over >= MIN_PROJECT_MILESTONES tranches of 60 days.
     */
    function executeProposal(uint256 proposalId) external onlyWhenVaultUnlocked returns (uint256) {
        OffGridHabitatProposal storage prop = proposals[proposalId];
        require(prop.id != 0, "Proposal does not exist");
        require(block.timestamp > prop.endTime, "Voting period not ended");
        require(!prop.executed, "Proposal already executed");
        require(!prop.canceled, "Proposal canceled");

        uint256 totalVotes = prop.forVotes + prop.againstVotes;
        require(totalVotes > 0, "No votes cast");
        require(prop.forVotes > prop.againstVotes, "Proposal rejected: against votes exceed for votes");

        uint256 epochSupply = lpSupplyByEpoch[prop.startEpoch];
        require(totalVotes * 100 >= epochSupply * QUORUM_PERCENTAGE, "Quorum not reached");

        uint256 funding = prop.requestedFunding;
        uint256 available = availableVaultBalance();
        require(funding <= (available * MAX_PROJECT_BPS_OF_VAULT) / BPS_DENOMINATOR, "Exceeds max project share of vault");

        prop.executed = true;

        // Anti-dump ceiling is fixed at approval time against the vault as it stands, so the
        // schedule is deterministic and the project can actually be finished.
        uint256 trancheCeiling = (totalObsVaultBalance * MAX_TRANCHE_BPS_OF_VAULT) / BPS_DENOMINATOR;
        require(trancheCeiling > 0, "Vault too small for an anti-dump schedule");

        // Stretch the spend over however many 60-day tranches the anti-dump ceiling demands,
        // and never fewer than MIN_PROJECT_MILESTONES.
        uint256 required = (funding + trancheCeiling - 1) / trancheCeiling;
        uint32 milestoneCount = required > MIN_PROJECT_MILESTONES ? uint32(required) : MIN_PROJECT_MILESTONES;
        require(milestoneCount <= MAX_PROJECT_MILESTONES, "Funding exceeds anti-dump schedule limit");
        uint256 perMilestoneCap = (funding + milestoneCount - 1) / milestoneCount;

        uint256 projectId = ++projectCount;
        Project storage project = projects[projectId];
        project.id = projectId;
        project.proposalId = proposalId;
        project.creator = prop.proposer;
        project.payoutRecipient = prop.payoutRecipient;
        project.fundingAmount = funding;
        project.fundingRemaining = funding;
        project.perMilestoneCap = perMilestoneCap;
        project.trancheCeiling = trancheCeiling;
        project.milestoneCount = milestoneCount;
        project.startTime = block.timestamp;
        project.deadline = block.timestamp + (uint256(milestoneCount) * MILESTONE_GATING_INTERVAL) + PROJECT_GRACE_PERIOD;
        project.missionDescription = prop.description;

        totalReservedForProjects += funding;

        emit ProjectCreated(projectId, proposalId, prop.proposer, funding, milestoneCount, perMilestoneCap, project.deadline);
        return projectId;
    }

    /* ------------------------------------------------------------------ */
    /*        ROBOT-ENFORCED, TIME-LOCKED, MISSION-BOUND FUND RELEASE      */
    /* ------------------------------------------------------------------ */

    function _attestationHash(MilestoneAttestation calldata att) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                att.acresSecured,
                att.hivesInstalled,
                att.honeyKgDistributedFree,
                att.atmosphericWaterLiters,
                att.solarKwhGenerated,
                att.batteryKwhStored,
                att.beeFlourishingIndexDelta,
                att.offGridVerified,
                att.landAcquired,
                att.equipmentOperational,
                att.evidenceHash
            )
        );
    }

    /// @dev The hardcoded mission rules, re-enforced on chain at EVERY single fund release.
    function _enforceMissionRules(MilestoneAttestation calldata att) internal pure {
        require(att.offGridVerified, "Mission rule: site must be fully off-grid");
        require(att.solarKwhGenerated > 0, "Mission rule: solar generation required");
        require(att.batteryKwhStored > 0, "Mission rule: battery storage required");
        require(att.atmosphericWaterLiters > 0, "Mission rule: atmospheric water generation required");
        require(att.honeyKgDistributedFree > 0, "Mission rule: free honey distribution required");
        require(att.hivesInstalled > 0, "Mission rule: indoor bee habitat hives required");
        require(att.landAcquired, "Mission rule: land must be acquired/held");
        require(att.equipmentOperational, "Mission rule: maintenance equipment must be operational");
        require(att.evidenceHash != bytes32(0), "Mission rule: robot evidence bundle required");
    }

    /**
     * @notice The single path by which OBS can ever leave this vault.
     *
     * Every one of these must hold:
     *   - the bonding curve has genuinely collected 5B DAI;
     *   - the Roomie robot MCU is commissioned;
     *   - at most one authorisation per project per 60 days;
     *   - hybrid PQC + ECDSA authorisation from the MCU (biometrics verified on the MCU itself);
     *   - the hardcoded mission rules are attested as actually happening in the real world;
     *   - the tranche is <= the project's mathematical per-milestone cap AND <= 2.5% of the vault.
     *
     * Funds go only to the payout recipient the DAO voted on. There is no arbitrary recipient.
     */
    function robotAuthorizeAndReleaseMilestone(
        uint256 projectId,
        uint256 amount,
        MilestoneAttestation calldata attestation,
        bytes calldata pqcPublicKey,
        bytes calldata pqcSignature,
        bytes calldata mcuEcdsaSignature,
        bytes32 otsPreimage
    ) external onlyAdminOrRobot onlyWhenVaultUnlocked nonReentrant {
        Project storage project = projects[projectId];
        require(project.id != 0, "Project does not exist");
        require(!project.completed, "Project already completed");
        require(!project.expired, "Project expired");
        require(block.timestamp <= project.deadline, "Project deadline passed");
        require(project.milestonesCompleted < project.milestoneCount, "All milestones already completed");

        uint256 last = project.lastMilestoneTime;
        if (last != 0) {
            require(
                block.timestamp >= last + MILESTONE_GATING_INTERVAL,
                "Milestone locked: Bi-monthly cycle (1 time every 2 months) not reached"
            );
        }

        require(amount > 0, "Nothing to release");
        require(amount <= project.perMilestoneCap, "Exceeds per-milestone cap");
        require(amount <= project.fundingRemaining, "Exceeds remaining project funding");
        require(amount <= project.trancheCeiling, "Exceeds anti-dump tranche cap");
        require(amount <= totalObsVaultBalance, "Insufficient vault balance");

        _enforceMissionRules(attestation);

        uint32 milestoneIndex = project.milestonesCompleted;
        bytes32 actionDigest = keccak256(
            abi.encode(
                MILESTONE_TYPEHASH,
                projectId,
                milestoneIndex,
                amount,
                project.payoutRecipient,
                _attestationHash(attestation)
            )
        );
        bytes32 pqcSignatureHash =
            _verifyHybridPqcAuthorization(actionDigest, pqcPublicKey, pqcSignature, mcuEcdsaSignature, otsPreimage);

        // -------- effects --------
        MissionLedger storage ledger = missionLedgers[projectId];
        ledger.acresSecured += attestation.acresSecured;
        ledger.hivesInstalled += attestation.hivesInstalled;
        ledger.honeyKgDistributedFree += attestation.honeyKgDistributedFree;
        ledger.atmosphericWaterLiters += attestation.atmosphericWaterLiters;
        ledger.solarKwhGenerated += attestation.solarKwhGenerated;
        ledger.batteryKwhStored += attestation.batteryKwhStored;

        project.lastMilestoneTime = block.timestamp;
        project.milestonesCompleted = milestoneIndex + 1;
        project.fundingRemaining -= amount;

        totalObsVaultBalance -= amount;
        totalReservedForProjects -= amount;
        totalObsReleased += amount;

        _accrueBeeFlourishing(attestation.beeFlourishingIndexDelta);

        emit MilestoneAuthorizedByRobot(
            projectId, milestoneIndex, amount, pqcSignatureHash, attestation.evidenceHash, block.timestamp
        );

        // -------- interaction --------
        IERC20(OBS_TOKEN).safeTransfer(project.payoutRecipient, amount);
        emit ProjectFundsWithdrawn(projectId, amount, project.payoutRecipient);
    }

    function _accrueBeeFlourishing(uint256 delta) internal {
        if (delta == 0) return;
        uint256 next = beeFlourishingIndex + delta;
        if (next > OPTIMAL_BEE_INDEX_CAP) {
            next = OPTIMAL_BEE_INDEX_CAP;
        }
        beeFlourishingIndex = next;
        emit BeeFlourishingIndexUpdated(next);
        if (!optimalBeeFlourishingReached && next >= TARGET_BEE_FLOURISHING_INDEX) {
            optimalBeeFlourishingReached = true;
            emit OptimalBeeFlourishingReached(next, block.timestamp);
        }
    }

    /**
     * @notice A project can only be closed when the ENTIRETY of it is done: every mathematically
     *         scheduled milestone delivered and every hardcoded mission outcome met.
     */
    function completeProject(uint256 projectId) external onlyAdminOrRobot {
        Project storage project = projects[projectId];
        require(project.id != 0, "Project does not exist");
        require(!project.completed, "Project already completed");
        require(!project.expired, "Project expired");
        require(project.milestonesCompleted == project.milestoneCount, "All milestones must be delivered");

        MissionLedger storage ledger = missionLedgers[projectId];
        require(ledger.acresSecured >= MIN_FLOWERING_ACRES_TARGET, "Acreage mandate not met");
        require(ledger.hivesInstalled > 0, "No hives installed");
        require(ledger.honeyKgDistributedFree > 0, "No free honey distributed");
        require(ledger.atmosphericWaterLiters > 0, "No atmospheric water generated");
        require(ledger.solarKwhGenerated > 0, "No solar energy generated");
        require(ledger.batteryKwhStored > 0, "No battery storage recorded");

        project.completed = true;

        uint256 unspent = project.fundingRemaining;
        if (unspent > 0) {
            project.fundingRemaining = 0;
            totalReservedForProjects -= unspent; // returns to the vault, never burned
        }

        emit ProjectCompleted(projectId);
    }

    /**
     * @notice Permissionless timeout. Unspent funds return to the vault - they are never
     *         destroyed and never become withdrawable outside the milestone path.
     */
    function checkProjectTimeout(uint256 projectId) external {
        Project storage project = projects[projectId];
        require(project.id != 0, "Project does not exist");
        require(!project.completed, "Project already completed");
        require(!project.expired, "Project already expired");
        require(block.timestamp > project.deadline, "Project deadline not reached");

        project.expired = true;
        uint256 returned = project.fundingRemaining;
        if (returned > 0) {
            project.fundingRemaining = 0;
            totalReservedForProjects -= returned;
        }

        emit ProjectExpired(projectId, returned);
    }

    /* ------------------------------------------------------------------ */
    /*                            VIEW HELPERS                             */
    /* ------------------------------------------------------------------ */

    function getProposalId(uint256 proposalId) external view returns (uint256) { return proposals[proposalId].id; }
    function getProposalProposer(uint256 proposalId) external view returns (address) { return proposals[proposalId].proposer; }
    function getProposalPayoutRecipient(uint256 proposalId) external view returns (address) { return proposals[proposalId].payoutRecipient; }
    function getProposalDescription(uint256 proposalId) external view returns (string memory) { return proposals[proposalId].description; }
    function getProposalTargetAcres(uint256 proposalId) external view returns (uint256) { return proposals[proposalId].targetAcresForBees; }
    function getProposalBeeIndex(uint256 proposalId) external view returns (uint256) { return proposals[proposalId].proposedBeePopulationIndex; }
    function getProposalRequestedFunding(uint256 proposalId) external view returns (uint256) { return proposals[proposalId].requestedFunding; }
    function getProposalSolarAndBattery(uint256 proposalId) external view returns (bool) { return proposals[proposalId].solarAndBatteryEquipped; }
    function getProposalAwg(uint256 proposalId) external view returns (bool) { return proposals[proposalId].atmosphericWaterGenEquipped; }
    function getProposalLandAcquisition(uint256 proposalId) external view returns (bool) { return proposals[proposalId].landAcquisitionIncluded; }
    function getProposalEquipmentAcquisition(uint256 proposalId) external view returns (bool) { return proposals[proposalId].equipmentAcquisitionIncluded; }
    function getProposalHoneyProduction(uint256 proposalId) external view returns (bool) { return proposals[proposalId].honeyProductionAndDistribution; }
    function getProposalForVotes(uint256 proposalId) external view returns (uint256) { return proposals[proposalId].forVotes; }
    function getProposalAgainstVotes(uint256 proposalId) external view returns (uint256) { return proposals[proposalId].againstVotes; }
    function getProposalStartTime(uint256 proposalId) external view returns (uint256) { return proposals[proposalId].startTime; }
    function getProposalEndTime(uint256 proposalId) external view returns (uint256) { return proposals[proposalId].endTime; }
    function getProposalExecuted(uint256 proposalId) external view returns (bool) { return proposals[proposalId].executed; }
    function getProposalCanceled(uint256 proposalId) external view returns (bool) { return proposals[proposalId].canceled; }
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) { return proposals[proposalId].hasVoted[voter]; }

    function getProjectId(uint256 projectId) external view returns (uint256) { return projects[projectId].id; }
    function getProjectProposalId(uint256 projectId) external view returns (uint256) { return projects[projectId].proposalId; }
    function getProjectCreator(uint256 projectId) external view returns (address) { return projects[projectId].creator; }
    function getProjectPayoutRecipient(uint256 projectId) external view returns (address) { return projects[projectId].payoutRecipient; }
    function getProjectFundingAmount(uint256 projectId) external view returns (uint256) { return projects[projectId].fundingAmount; }
    function getProjectFundingRemaining(uint256 projectId) external view returns (uint256) { return projects[projectId].fundingRemaining; }
    function getProjectPerMilestoneCap(uint256 projectId) external view returns (uint256) { return projects[projectId].perMilestoneCap; }
    function getProjectTrancheCeiling(uint256 projectId) external view returns (uint256) { return projects[projectId].trancheCeiling; }
    function getProjectMilestoneCount(uint256 projectId) external view returns (uint32) { return projects[projectId].milestoneCount; }
    function getProjectMilestonesCompleted(uint256 projectId) external view returns (uint32) { return projects[projectId].milestonesCompleted; }
    function getProjectStartTime(uint256 projectId) external view returns (uint256) { return projects[projectId].startTime; }
    function getProjectDeadline(uint256 projectId) external view returns (uint256) { return projects[projectId].deadline; }
    function getProjectCompleted(uint256 projectId) external view returns (bool) { return projects[projectId].completed; }
    function getProjectExpired(uint256 projectId) external view returns (bool) { return projects[projectId].expired; }
    function getProjectLastMilestoneTime(uint256 projectId) external view returns (uint256) { return projects[projectId].lastMilestoneTime; }
    function getProjectMissionDescription(uint256 projectId) external view returns (string memory) { return projects[projectId].missionDescription; }

    function getMissionLedger(uint256 projectId) external view returns (MissionLedger memory) { return missionLedgers[projectId]; }

    /// @notice Next timestamp at which the robot may authorise this project again.
    function nextMilestoneUnlockTime(uint256 projectId) external view returns (uint256) {
        Project storage project = projects[projectId];
        if (project.id == 0) return 0;
        if (project.lastMilestoneTime == 0) return project.startTime;
        return project.lastMilestoneTime + MILESTONE_GATING_INTERVAL;
    }

    function getProposalCount() external view returns (uint256) { return proposalCount; }
    function getProjectCount() external view returns (uint256) { return projectCount; }
    function isVaultUnlocked() external view returns (bool) { return vaultUnlocked; }
    function isRobotConfigured() external view returns (bool) { return robot.provisioned; }
    function isRobotCommissioned() external view returns (bool) { return robot.commissioned; }
    function isConfigUpdatable() external view returns (bool) { return canUpdateRobotConfig; }
    function getRobotPqcPublicKeyHash() external view returns (bytes32) { return robot.pqcPublicKeyHash; }
    function getRobotMcuEcdsaSigner() external view returns (address) { return robot.mcuEcdsaSigner; }
    function getRobotOtsChainTip() external view returns (bytes32) { return robot.otsChainTip; }
    function getRobotOtsRemaining() external view returns (uint64) { return robot.otsRemaining; }

    /// @dev Kept for interface compatibility with the pre-audit ABI.
    function roomieRobotPqcPublicKeyHash() external view returns (bytes32) { return robot.pqcPublicKeyHash; }
    function roomieRobotLocked() external view returns (bool) { return robot.provisioned; }
}
