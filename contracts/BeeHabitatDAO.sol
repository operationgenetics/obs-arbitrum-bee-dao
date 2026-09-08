// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title  BeeHabitatDAO
 * @notice Immutable, zero-configuration DAO and OBS vault for the Obscura ecosystem on
 *         Arbitrum One, funding off-grid indoor bee habitats.
 * @dev    Deployed with no constructor arguments, no initializer, no proxy, no owner, no pause
 *         switch and no upgrade path. Every address and parameter is a compile-time `constant`.
 *
 *         Security model, in order of precedence:
 *
 *         1. NOTHING leaves the vault until the OBS bonding curve has genuinely collected
 *            5,000,000,000 DAI, read trustlessly from the OBS token itself. There is no oracle,
 *            no relayer and no caller-supplied figure anywhere in the unlock path.
 *         2. The single outbound transfer in this contract lives in
 *            {robotAuthorizeAndReleaseMilestone} and pays only the recipient the DAO voted on.
 *         3. That release requires a hybrid post-quantum authorization from the Roomie humanoid
 *            robot's PQC MCU. Biometric templates never touch the chain; only public
 *            commitments do. See {_verifyHybridPqcAuthorization}.
 *         4. Releases are mathematically time-locked into at least six 60-day tranches, each
 *            capped as a fraction of the vault, so the treasury cannot be drained quickly.
 *         5. The hardcoded mission rules are re-enforced on chain at every single release
 *            against a robot-signed real-world attestation, and again at project completion.
 *
 *         Checks-Effects-Interactions is observed throughout; the one external token call is
 *         made last and is additionally protected by {ReentrancyGuard}.
 *
 * @custom:security-contact operationgenetics@proton.me
 */
contract BeeHabitatDAO is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ====================================================================== */
    /*                                 ERRORS                                 */
    /* ====================================================================== */

    /// @dev Caller is not the hardcoded orchestrator wallet.
    error Unauthorized();
    /// @dev Robot configuration has been permanently frozen by {revokeAndUpdateImmutability}.
    error ConfigurationImmutable();
    error InvalidPqcPublicKeyHash();
    error InvalidMcuSigner();
    error InvalidOtsChainTip();
    error InvalidOtsChainLength();
    error RobotNotProvisioned();
    error RobotNotCommissioned();
    error PqcPublicKeyTooShort();
    error PqcPublicKeyMismatch();
    error OtsChainExhausted();
    error InvalidOtsPreimage();
    error PqcSignatureTooShort();
    error InvalidEcdsaSignatureLength();
    error InvalidEcdsaSignatureV();
    error MalleableEcdsaSignature();
    error InvalidEcdsaSignature();
    error EcdsaSignerMismatch();

    error VaultAlreadyUnlocked();
    /// @dev The OBS bonding curve has not yet collected {BONDING_CURVE_DAI_UNLOCK_TARGET} DAI.
    error BondingCurveTargetNotReached();
    error VaultLocked();
    error NothingToDeposit();
    error NothingToSync();
    error InsufficientVaultBalance();

    error InvalidRecipient();
    error NothingToIssue();
    error ExceedsMonthlyIssuanceLimit();

    error InsufficientLpToPropose();
    error DescriptionRequired();
    error FundingRequired();
    error BelowMinimumAcreage();
    error ExceedsBeeIndexCap();
    error SolarAndBatteryRequired();
    error AtmosphericWaterRequired();
    error LandAcquisitionRequired();
    error EquipmentAcquisitionRequired();
    error HoneyDistributionRequired();

    error ProposalNotFound();
    error VotingInactive();
    error AlreadyVoted();
    error NoVotingPower();
    error VotingNotEnded();
    error ProposalAlreadyExecuted();
    error NoVotesCast();
    error ProposalRejected();
    error QuorumNotReached();
    error ExceedsMaxProjectShare();
    error VaultTooSmallForSchedule();
    error ExceedsScheduleLimit();

    error ProjectNotFound();
    error ProjectAlreadyCompleted();
    error ProjectHasExpired();
    error ProjectAlreadyExpired();
    error ProjectDeadlinePassed();
    error ProjectDeadlineNotReached();
    error AllMilestonesCompleted();
    error MilestonesIncomplete();
    /// @dev Only one robot authorization per project per {MILESTONE_GATING_INTERVAL}.
    error MilestoneLocked();
    error NothingToRelease();
    error ExceedsPerMilestoneCap();
    error ExceedsRemainingFunding();
    error ExceedsTrancheCap();

    error MissionRuleOffGridRequired();
    error MissionRuleSolarRequired();
    error MissionRuleBatteryRequired();
    error MissionRuleWaterRequired();
    error MissionRuleHoneyRequired();
    error MissionRuleHivesRequired();
    error MissionRuleLandRequired();
    error MissionRuleEquipmentRequired();
    error MissionRuleEvidenceRequired();
    error MissionOutcomeNotMet();

    /* ====================================================================== */
    /*                        IMMUTABLE ON-CHAIN WIRING                       */
    /* ====================================================================== */

    /// @notice Obscura (OBS) on Arbitrum One. Verified: name "Obscura", symbol "OBS", 18 decimals.
    address public constant OBS_TOKEN = 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;

    /// @notice The only wallet that may provision, rotate or freeze the Roomie robot credential
    ///         and drive operations. Hardcoded; it cannot be transferred or renounced.
    address public constant ADMIN_ORCHESTRATOR = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    /// @notice 5 billion DAI (18 decimals) of real bonding-curve reserves unlocks the vault.
    uint256 public constant BONDING_CURVE_DAI_UNLOCK_TARGET = 5_000_000_000 * 1e18;

    /// @dev `daiReserve()` on the OBS token: the live bonding-curve reserve.
    bytes4 private constant SEL_DAI_RESERVE = 0xe2771ec8;
    /// @dev `totalDaiCollected()` on the OBS token: cumulative DAI taken in by the curve.
    bytes4 private constant SEL_TOTAL_DAI_COLLECTED = 0x57d0e873;

    /* ====================================================================== */
    /*                      HARDCODED MISSION PARAMETERS                      */
    /* ====================================================================== */

    /// @notice Geographic mandate for every funded habitat.
    string public constant HABITAT_FOCUS_ZONE =
        "Nationwide United States Off-Grid Indoor & Regional Pollinator Corridors";

    /// @notice The mission the robots are bound to. Enforced by code, not convention.
    string public constant MISSION_MANDATE =
        "Off-grid indoor bee habitats with atmospheric water generation, solar generation and "
        "battery storage; honey farmed and given away free; land and equipment acquired and "
        "maintained indefinitely until the optimal bee flourishing index is reached.";

    /// @notice Minimum flowering acreage any funded habitat must forage.
    uint256 public constant MIN_FLOWERING_ACRES_TARGET = 20;
    /// @notice Safe carrying-capacity ceiling for the bee population index.
    uint256 public constant OPTIMAL_BEE_INDEX_CAP = 500_000;
    /// @notice Global flourishing target. Operations continue indefinitely until it is met.
    uint256 public constant TARGET_BEE_FLOURISHING_INDEX = 500_000;

    /* ====================================================================== */
    /*                     HARDCODED GOVERNANCE PARAMETERS                    */
    /* ====================================================================== */

    /// @notice 100 LP per member per month, cumulative across all issuances in that month.
    uint256 public constant MONTHLY_LP_ISSUANCE = 100 * 1e18;
    /// @notice 50 unexpired LP are required to open a proposal.
    uint256 public constant PROPOSAL_THRESHOLD = 50 * 1e18;
    uint256 public constant VOTING_PERIOD_DURATION = 30 days;
    /// @notice LP expires at the end of each epoch and is never carried forward.
    uint256 public constant LP_EPOCH = 30 days;
    /// @notice The robot may authorize a given project once every 60 days.
    uint256 public constant MILESTONE_GATING_INTERVAL = 60 days;
    /// @notice Percentage of the epoch's live LP supply that must vote for a proposal to pass.
    uint256 public constant QUORUM_PERCENTAGE = 10;

    /* ====================================================================== */
    /*                   HARDCODED ANTI-DUMP / TIME-LOCK RULES                */
    /* ====================================================================== */

    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice No single project may reserve more than 20% of the unreserved vault.
    uint256 public constant MAX_PROJECT_BPS_OF_VAULT = 2_000;
    /// @notice No single 60-day tranche may exceed 2.5% of the vault balance at approval time.
    uint256 public constant MAX_TRANCHE_BPS_OF_VAULT = 250;
    /// @notice Every project is stretched over at least six tranches, so at least twelve months.
    uint32 public constant MIN_PROJECT_MILESTONES = 6;
    uint32 public constant MAX_PROJECT_MILESTONES = 120;
    uint256 public constant PROJECT_GRACE_PERIOD = 90 days;

    /* ====================================================================== */
    /*                      HYBRID PQC CREDENTIAL RULES                       */
    /* ====================================================================== */

    /// @notice Minimum PQC signature size, chosen to reject classically-sized signatures.
    /// @dev Falcon-512 is 666 bytes, ML-DSA-44 is 2420, SPHINCS+-128s is 7856.
    uint256 public constant MIN_PQC_SIGNATURE_BYTES = 512;
    /// @notice Minimum PQC public key size. SPHINCS+ public keys are only 32 bytes.
    uint256 public constant MIN_PQC_PUBLIC_KEY_BYTES = 32;

    /// @dev secp256k1 group order halved; signatures above this are malleable and rejected.
    uint256 private constant SECP256K1_HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice Domain separator for a milestone authorization signed by the Roomie MCU.
    bytes32 public constant MILESTONE_TYPEHASH = keccak256(
        "RoomieMilestoneAuthorization(uint256 projectId,uint32 milestoneIndex,uint256 amount,address recipient,bytes32 attestationHash)"
    );

    /* ====================================================================== */
    /*                                 TYPES                                  */
    /* ====================================================================== */

    /**
     * @notice The Roomie humanoid robot's hybrid post-quantum credential.
     * @dev Biometric templates are hard-locked inside the MCU secure element and are never
     *      written on chain. Only public commitments live here.
     *
     *      Hybrid means an attacker must break both legs, not either one:
     *        - classical leg: secp256k1 ECDSA from the MCU's classical key;
     *        - quantum leg:   keccak256 pre-image resistance, via the PQC public-key commitment
     *          and a one-time-signature hash chain. Neither is broken by Shor's algorithm.
     *
     * @param pqcPublicKeyHash keccak256 of the full PQC public key stored on the MCU.
     * @param mcuEcdsaSigner   secp256k1 address derived inside the MCU secure element.
     * @param otsChainTip      Current tip of the MCU's one-time-signature hash chain.
     * @param otsRemaining     Authorizations the chain can still serve.
     * @param provisioned      Day-one provisional setup has been done.
     * @param commissioned     Real hardware is bound, so spending is cryptographically possible.
     */
    struct RobotCredential {
        bytes32 pqcPublicKeyHash;
        address mcuEcdsaSigner;
        bytes32 otsChainTip;
        uint64 otsRemaining;
        bool provisioned;
        bool commissioned;
    }

    /// @notice A member's expiring LP position for a single epoch.
    struct LpTokenLedger {
        uint256 balance;
        uint256 epoch;
    }

    /// @notice A mission-constrained funding proposal.
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
        mapping(address => bool) hasVoted;
    }

    /// @notice An approved project and its mathematically derived release schedule.
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

    /// @notice Cumulative real-world delivery for a project, attested at every tranche.
    struct MissionLedger {
        uint256 acresSecured;
        uint256 hivesInstalled;
        uint256 honeyKgDistributedFree;
        uint256 atmosphericWaterLiters;
        uint256 solarKwhGenerated;
        uint256 batteryKwhStored;
    }

    /// @notice One tranche's worth of robot-verified, real-world evidence.
    /// @dev Every field is bound into the signed digest; changing any byte invalidates it.
    struct MilestoneAttestation {
        uint256 acresSecured;
        uint256 hivesInstalled;
        uint256 honeyKgDistributedFree;
        uint256 atmosphericWaterLiters;
        uint256 solarKwhGenerated;
        uint256 batteryKwhStored;
        uint256 beeFlourishingIndexDelta;
        bool offGridVerified;
        bool landAcquired;
        bool equipmentOperational;
        bytes32 evidenceHash;
    }

    /* ====================================================================== */
    /*                                STORAGE                                 */
    /* ====================================================================== */

    /// @notice The bound Roomie robot credential.
    RobotCredential public robot;

    /// @notice False once {revokeAndUpdateImmutability} is signed. It never returns to true.
    bool public canUpdateRobotConfig = true;

    /// @notice Set once by {checkAndUnlockVault}. One-way; it can never be unset.
    bool public vaultUnlocked;

    /// @notice OBS credited to the vault.
    uint256 public totalObsVaultBalance;
    /// @notice OBS committed to live projects and therefore unavailable to new ones.
    uint256 public totalReservedForProjects;
    /// @notice OBS released to habitat operators to date.
    uint256 public totalObsReleased;

    /// @notice Cumulative, robot-attested bee flourishing index across all projects.
    uint256 public beeFlourishingIndex;
    /// @notice True once {beeFlourishingIndex} reaches {TARGET_BEE_FLOURISHING_INDEX}.
    bool public optimalBeeFlourishingReached;

    mapping(address account => LpTokenLedger ledger) public monthlyLpBalances;
    /// @notice Live LP issued per epoch. This is the quorum denominator.
    mapping(uint256 epoch => uint256 supply) public lpSupplyByEpoch;

    mapping(uint256 proposalId => OffGridHabitatProposal proposal) private _proposals;
    uint256 public proposalCount;

    mapping(uint256 projectId => Project project) private _projects;
    mapping(uint256 projectId => MissionLedger ledger) private _missionLedgers;
    uint256 public projectCount;

    /* ====================================================================== */
    /*                                 EVENTS                                 */
    /* ====================================================================== */

    event RoomieRobotProvisioned(bytes32 indexed pqcPublicKeyHash);
    event RoomieRobotCommissioned(
        bytes32 indexed pqcPublicKeyHash,
        address indexed mcuEcdsaSigner,
        bytes32 otsChainTip,
        uint64 otsChainLength
    );
    event RoomieRobotConfigured(bytes32 indexed pqcPublicKeyHash);
    event RobotConfigRevoked();

    event VaultUnlockedByBondingCurve(uint256 daiReserves);
    event VaultDeposit(address indexed from, uint256 amount);
    event VaultSynced(uint256 credited, uint256 newBalance);

    event LpTokensIssued(address indexed recipient, uint256 amount, uint256 indexed epoch);
    event OffGridBeeHabitatProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string description,
        uint256 targetAcres,
        uint256 proposedBeePopulationIndex,
        uint256 requestedFunding,
        address payoutRecipient
    );
    event Voted(uint256 indexed proposalId, address indexed voter, uint256 weight, bool support);

    event ProjectCreated(
        uint256 indexed projectId,
        uint256 indexed proposalId,
        address indexed creator,
        uint256 fundingAmount,
        uint32 milestoneCount,
        uint256 perMilestoneCap,
        uint256 deadline
    );
    event MilestoneAuthorizedByRobot(
        uint256 indexed projectId,
        uint32 indexed milestoneIndex,
        uint256 amount,
        bytes32 pqcSignatureHash,
        bytes32 evidenceHash,
        uint256 timestamp
    );
    event ProjectFundsWithdrawn(uint256 indexed projectId, uint256 amount, address indexed recipient);
    event ProjectCompleted(uint256 indexed projectId);
    event ProjectExpired(uint256 indexed projectId, uint256 fundsReturnedToVault);

    event BeeFlourishingIndexUpdated(uint256 newIndex);
    event OptimalBeeFlourishingReached(uint256 index, uint256 timestamp);

    /* ====================================================================== */
    /*                               MODIFIERS                                */
    /* ====================================================================== */

    modifier onlyAdminOrRobot() {
        if (msg.sender != ADMIN_ORCHESTRATOR) revert Unauthorized();
        _;
    }

    modifier onlyWhenVaultUnlocked() {
        if (!vaultUnlocked) revert VaultLocked();
        _;
    }

    modifier onlyWhileConfigurable() {
        if (!canUpdateRobotConfig) revert ConfigurationImmutable();
        _;
    }

    /// @dev Zero-config by design: deployment takes no arguments and performs no setup.
    constructor() {}

    /// @notice The OBS token this vault holds.
    function obsToken() external pure returns (address) {
        return OBS_TOKEN;
    }

    /* ====================================================================== */
    /*             ROOMIE ROBOT HYBRID PQC CREDENTIAL LIFECYCLE               */
    /* ====================================================================== */

    /**
     * @notice Anchors the Roomie robot slot with a provisional PQC public-key commitment.
     *         Callable the moment the contract exists.
     * @dev Provisional only. It deliberately does NOT enable spending; that requires
     *      {commissionRoomieRobot} with the real MCU credential.
     * @param pqcPublicKeyHash keccak256 of the placeholder or real PQC public key.
     */
    function setupRoomieRobotAndLock(bytes32 pqcPublicKeyHash)
        external
        onlyAdminOrRobot
        onlyWhileConfigurable
    {
        if (pqcPublicKeyHash == bytes32(0)) revert InvalidPqcPublicKeyHash();

        robot.pqcPublicKeyHash = pqcPublicKeyHash;
        robot.provisioned = true;

        emit RoomieRobotProvisioned(pqcPublicKeyHash);
        emit RoomieRobotConfigured(pqcPublicKeyHash);
    }

    /**
     * @notice Binds the real credential once the Roomie robot and its hybrid PQC MCU arrive.
     * @dev Biometric templates stay hard-locked on the MCU and are never part of this call.
     *      May be re-run to rotate the credential until {revokeAndUpdateImmutability}.
     * @param pqcPublicKeyHash keccak256 of the MCU's full PQC public key.
     * @param mcuEcdsaSigner   secp256k1 address derived inside the MCU secure element.
     * @param otsChainTip      s_N, where s_i = keccak256(abi.encodePacked(s_{i-1})) and the MCU
     *                         alone holds the seed s_0.
     * @param otsChainLength   Number of authorizations the chain can serve. This is a hard
     *                         ceiling on how many releases the credential can ever approve.
     */
    function commissionRoomieRobot(
        bytes32 pqcPublicKeyHash,
        address mcuEcdsaSigner,
        bytes32 otsChainTip,
        uint64 otsChainLength
    ) external onlyAdminOrRobot onlyWhileConfigurable {
        if (pqcPublicKeyHash == bytes32(0)) revert InvalidPqcPublicKeyHash();
        if (mcuEcdsaSigner == address(0)) revert InvalidMcuSigner();
        if (otsChainTip == bytes32(0)) revert InvalidOtsChainTip();
        if (otsChainLength == 0) revert InvalidOtsChainLength();

        robot.pqcPublicKeyHash = pqcPublicKeyHash;
        robot.mcuEcdsaSigner = mcuEcdsaSigner;
        robot.otsChainTip = otsChainTip;
        robot.otsRemaining = otsChainLength;
        robot.provisioned = true;
        robot.commissioned = true;

        emit RoomieRobotCommissioned(pqcPublicKeyHash, mcuEcdsaSigner, otsChainTip, otsChainLength);
        emit RoomieRobotConfigured(pqcPublicKeyHash);
    }

    /**
     * @notice Rotates only the PQC public-key commitment, for an MCU firmware or key refresh.
     * @param newPqcPublicKeyHash keccak256 of the replacement PQC public key.
     */
    function updateRobotPqcPublicKey(bytes32 newPqcPublicKeyHash)
        external
        onlyAdminOrRobot
        onlyWhileConfigurable
    {
        if (!robot.provisioned) revert RobotNotProvisioned();
        if (newPqcPublicKeyHash == bytes32(0)) revert InvalidPqcPublicKeyHash();

        robot.pqcPublicKeyHash = newPqcPublicKeyHash;
        emit RoomieRobotConfigured(newPqcPublicKeyHash);
    }

    /**
     * @notice FINAL AND IRREVERSIBLE. Freezes the robot configuration forever.
     * @dev After this call the PQC public key, MCU signer and OTS chain can never be changed
     *      again by anyone, the orchestrator included. Governance, releases and completion
     *      continue to operate under the now-permanent credential.
     *
     *      Ordering matters: revoking before {commissionRoomieRobot} permanently prevents every
     *      fund release, because the commissioned flag can no longer be set.
     */
    function revokeAndUpdateImmutability() external onlyAdminOrRobot onlyWhileConfigurable {
        canUpdateRobotConfig = false;
        emit RobotConfigRevoked();
    }

    /**
     * @dev Minimal, self-contained secp256k1 recovery. Rejects malformed and malleable (high-s)
     *      signatures and the zero address, so a forged signature can never resolve to an unset
     *      signer. Inlined deliberately: an immutable contract should carry no avoidable
     *      dependency, and this keeps the verified surface small enough to read in full.
     * @param digest    The EIP-191 digest that was signed.
     * @param signature 65-byte (r, s, v) signature.
     * @return The recovered signer address.
     */
    function _recoverSigner(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) revert InvalidEcdsaSignatureLength();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        if (v < 27) {
            unchecked {
                v += 27;
            }
        }
        if (v != 27 && v != 28) revert InvalidEcdsaSignatureV();
        if (uint256(s) > SECP256K1_HALF_N) revert MalleableEcdsaSignature();

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidEcdsaSignature();
        return signer;
    }

    /**
     * @dev Hybrid post-quantum and classical verification of one MCU authorization.
     *
     *      Leg 1, post-quantum identity:      the full PQC public key must hash to the anchored
     *                                         commitment.
     *      Leg 2, post-quantum authorization: reveal the next link of the MCU's keccak256
     *                                         one-time-signature chain. Single-use, replay-proof
     *                                         and forward-secure against a quantum adversary.
     *      Leg 3, post-quantum anchoring:     the full PQC signature is hashed and bound in, so
     *                                         the robot fleet can verify it off chain against
     *                                         the anchored public key.
     *      Leg 4, classical:                  secp256k1 ECDSA over a domain-separated digest
     *                                         binding legs 1 to 3, the chain id and this
     *                                         contract's address.
     *
     *      Forging an authorization therefore requires breaking secp256k1 AND keccak256
     *      pre-image resistance. Breaking either one alone is not sufficient.
     *
     * @return pqcSignatureHash keccak256 of the supplied PQC signature, emitted for auditors.
     */
    function _verifyHybridPqcAuthorization(
        bytes32 actionDigest,
        bytes calldata pqcPublicKey,
        bytes calldata pqcSignature,
        bytes calldata mcuEcdsaSignature,
        bytes32 otsPreimage
    ) private returns (bytes32 pqcSignatureHash) {
        RobotCredential storage cred = robot;
        if (!cred.commissioned) revert RobotNotCommissioned();

        // Leg 1: post-quantum identity commitment.
        if (pqcPublicKey.length < MIN_PQC_PUBLIC_KEY_BYTES) revert PqcPublicKeyTooShort();
        bytes32 anchoredKeyHash = cred.pqcPublicKeyHash;
        if (keccak256(pqcPublicKey) != anchoredKeyHash) revert PqcPublicKeyMismatch();

        // Leg 2: post-quantum one-time-signature chain link.
        if (cred.otsRemaining == 0) revert OtsChainExhausted();
        if (keccak256(abi.encodePacked(otsPreimage)) != cred.otsChainTip) revert InvalidOtsPreimage();

        // Leg 3: anchor the full PQC signature.
        if (pqcSignature.length < MIN_PQC_SIGNATURE_BYTES) revert PqcSignatureTooShort();
        pqcSignatureHash = keccak256(pqcSignature);

        // Leg 4: classical secp256k1 over everything above, domain separated.
        bytes32 payload = keccak256(
            abi.encode(
                block.chainid, address(this), actionDigest, anchoredKeyHash, pqcSignatureHash, otsPreimage
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payload));
        if (_recoverSigner(digest, mcuEcdsaSignature) != cred.mcuEcdsaSigner) revert EcdsaSignerMismatch();

        // Consume the one-time link, advancing the tip so this preimage can never be reused.
        cred.otsChainTip = otsPreimage;
        unchecked {
            cred.otsRemaining -= 1;
        }
    }

    /* ====================================================================== */
    /*                 TRUSTLESS BONDING-CURVE VAULT UNLOCK                   */
    /* ====================================================================== */

    /**
     * @notice Reads the OBS bonding-curve DAI reserves directly from the OBS token contract.
     * @dev Fully off-grid: no oracle, no relayer, no caller-supplied value. Falls back to
     *      `totalDaiCollected()` and finally to zero, so the unlock always fails closed rather
     *      than open if the token's interface is ever unavailable.
     * @return The curve's DAI reserves, in DAI wei.
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

    /**
     * @notice Unlocks the vault once the curve genuinely holds 5,000,000,000 DAI.
     * @dev Permissionless and argument-free by design. Not even the orchestrator can unlock an
     *      under-funded curve, because there is no value for a caller to supply.
     */
    function checkAndUnlockVault() external {
        if (vaultUnlocked) revert VaultAlreadyUnlocked();

        uint256 reserves = bondingCurveDaiReserves();
        if (reserves < BONDING_CURVE_DAI_UNLOCK_TARGET) revert BondingCurveTargetNotReached();

        vaultUnlocked = true;
        emit VaultUnlockedByBondingCurve(reserves);
    }

    /* ====================================================================== */
    /*                      OBS VAULT: RECEIVE AND HOLD                       */
    /* ====================================================================== */

    /**
     * @notice Deposits OBS into the vault.
     * @dev Credits the balance actually received, so a fee-on-transfer or rebasing OBS cannot
     *      desynchronise internal accounting from the token balance.
     * @param amount OBS to pull from the caller. Requires prior approval.
     */
    function depositToVault(uint256 amount) external nonReentrant {
        if (amount == 0) revert NothingToDeposit();

        uint256 balanceBefore = IERC20(OBS_TOKEN).balanceOf(address(this));
        IERC20(OBS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(OBS_TOKEN).balanceOf(address(this)) - balanceBefore;

        totalObsVaultBalance += received;
        emit VaultDeposit(msg.sender, received);
    }

    /**
     * @notice Credits OBS that was sent to the vault by a plain `transfer`.
     * @dev Permissionless. Donations can only ever increase the vault.
     * @return credited The newly credited amount.
     */
    function syncVault() external returns (uint256 credited) {
        uint256 actual = IERC20(OBS_TOKEN).balanceOf(address(this));
        uint256 tracked = totalObsVaultBalance;
        if (actual <= tracked) revert NothingToSync();

        unchecked {
            credited = actual - tracked;
        }
        totalObsVaultBalance = actual;
        emit VaultSynced(credited, actual);
    }

    /// @notice The vault's live OBS token balance.
    function getVaultBalance() external view returns (uint256) {
        return IERC20(OBS_TOKEN).balanceOf(address(this));
    }

    /// @notice Vault OBS not already committed to a live project.
    function availableVaultBalance() public view returns (uint256) {
        uint256 tracked = totalObsVaultBalance;
        uint256 reserved = totalReservedForProjects;
        return tracked > reserved ? tracked - reserved : 0;
    }

    /* ====================================================================== */
    /*         MONTHLY LP: 100 PER MONTH, EXPIRING, ONE LP IS ONE VOTE        */
    /* ====================================================================== */

    /// @notice The current 30-day LP epoch index.
    function currentEpoch() public view returns (uint256) {
        return block.timestamp / LP_EPOCH;
    }

    /**
     * @notice Issues expiring LP to a member.
     * @dev The 100 LP ceiling is cumulative per member per month, not per call. Unused LP
     *      expires at the epoch boundary and is never carried forward.
     * @param recipient Member receiving the LP.
     * @param amount    LP to issue, in wei.
     */
    function issueMonthlyLpTokens(address recipient, uint256 amount) external onlyAdminOrRobot {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert NothingToIssue();

        uint256 epoch = currentEpoch();
        LpTokenLedger storage ledger = monthlyLpBalances[recipient];
        uint256 alreadyThisMonth = ledger.epoch == epoch ? ledger.balance : 0;
        if (alreadyThisMonth + amount > MONTHLY_LP_ISSUANCE) revert ExceedsMonthlyIssuanceLimit();

        ledger.balance = alreadyThisMonth + amount;
        ledger.epoch = epoch;
        lpSupplyByEpoch[epoch] += amount;

        emit LpTokensIssued(recipient, amount, epoch);
    }

    /**
     * @notice One LP is one vote. Returns zero once the LP has expired.
     * @param account The member to inspect.
     */
    function getVotingPower(address account) public view returns (uint256) {
        LpTokenLedger storage ledger = monthlyLpBalances[account];
        if (ledger.epoch < currentEpoch()) {
            return 0;
        }
        return ledger.balance;
    }

    /// @notice Live, unexpired LP supply. This is the quorum denominator.
    function getTotalActiveLpSupply() public view returns (uint256) {
        return lpSupplyByEpoch[currentEpoch()];
    }

    /* ====================================================================== */
    /*                    PROPOSALS: MISSION-CONSTRAINED                      */
    /* ====================================================================== */

    /**
     * @notice Opens a funding proposal for an off-grid indoor bee habitat.
     * @dev Requires 50 unexpired LP. Every hardcoded mission rule is checked here and again at
     *      each fund release. The funding amount and payout recipient are fixed now and cannot
     *      be chosen later at execution time.
     * @param description                   Human-readable mission description.
     * @param targetAcresForBees            Flowering acreage the habitat will forage.
     * @param proposedBeePopulationIndex    Target bee population index, capped for safety.
     * @param requestedFunding              OBS requested, in wei.
     * @param payoutRecipient               The only address this project can ever pay.
     * @param solarAndBatteryEquipped       Must be true.
     * @param atmosphericWaterGenEquipped   Must be true.
     * @param landAcquisitionIncluded       Must be true.
     * @param equipmentAcquisitionIncluded  Must be true.
     * @param honeyProductionAndDistribution Must be true.
     * @return proposalId The new proposal's id.
     */
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
    ) external returns (uint256 proposalId) {
        if (getVotingPower(msg.sender) < PROPOSAL_THRESHOLD) revert InsufficientLpToPropose();
        if (bytes(description).length == 0) revert DescriptionRequired();
        if (requestedFunding == 0) revert FundingRequired();
        if (payoutRecipient == address(0)) revert InvalidRecipient();
        if (targetAcresForBees < MIN_FLOWERING_ACRES_TARGET) revert BelowMinimumAcreage();
        if (proposedBeePopulationIndex > OPTIMAL_BEE_INDEX_CAP) revert ExceedsBeeIndexCap();
        if (!solarAndBatteryEquipped) revert SolarAndBatteryRequired();
        if (!atmosphericWaterGenEquipped) revert AtmosphericWaterRequired();
        if (!landAcquisitionIncluded) revert LandAcquisitionRequired();
        if (!equipmentAcquisitionIncluded) revert EquipmentAcquisitionRequired();
        if (!honeyProductionAndDistribution) revert HoneyDistributionRequired();

        proposalId = ++proposalCount;
        OffGridHabitatProposal storage prop = _proposals[proposalId];
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
    }

    /**
     * @notice Casts a vote weighted one-to-one by the caller's unexpired LP.
     * @param proposalId The proposal to vote on.
     * @param support    True to vote for, false against.
     */
    function vote(uint256 proposalId, bool support) external {
        OffGridHabitatProposal storage prop = _proposals[proposalId];
        if (prop.id == 0) revert ProposalNotFound();
        if (block.timestamp < prop.startTime || block.timestamp > prop.endTime) revert VotingInactive();
        if (prop.hasVoted[msg.sender]) revert AlreadyVoted();

        uint256 weight = getVotingPower(msg.sender);
        if (weight == 0) revert NoVotingPower();

        prop.hasVoted[msg.sender] = true;
        if (support) {
            prop.forVotes += weight;
        } else {
            prop.againstVotes += weight;
        }

        emit Voted(proposalId, msg.sender, weight, support);
    }

    /**
     * @notice Executes a passed proposal into a funded, time-locked project.
     * @dev Permissionless: the funding amount and recipient come from the proposal the DAO
     *      voted on, so an executor has nothing left to choose. The spend is stretched over
     *      max(MIN_PROJECT_MILESTONES, ceil(funding / trancheCeiling)) tranches of 60 days.
     * @param proposalId The proposal to execute.
     * @return projectId The new project's id.
     */
    function executeProposal(uint256 proposalId)
        external
        onlyWhenVaultUnlocked
        returns (uint256 projectId)
    {
        OffGridHabitatProposal storage prop = _proposals[proposalId];
        if (prop.id == 0) revert ProposalNotFound();
        if (block.timestamp <= prop.endTime) revert VotingNotEnded();
        if (prop.executed) revert ProposalAlreadyExecuted();

        uint256 forVotes = prop.forVotes;
        uint256 againstVotes = prop.againstVotes;
        uint256 totalVotes = forVotes + againstVotes;
        if (totalVotes == 0) revert NoVotesCast();
        if (forVotes <= againstVotes) revert ProposalRejected();
        if (totalVotes * 100 < lpSupplyByEpoch[prop.startEpoch] * QUORUM_PERCENTAGE) {
            revert QuorumNotReached();
        }

        uint256 funding = prop.requestedFunding;
        if (funding > (availableVaultBalance() * MAX_PROJECT_BPS_OF_VAULT) / BPS_DENOMINATOR) {
            revert ExceedsMaxProjectShare();
        }

        // The anti-dump ceiling is fixed at approval time against the vault as it stands, so the
        // schedule is deterministic and the project can actually be finished.
        uint256 trancheCeiling = (totalObsVaultBalance * MAX_TRANCHE_BPS_OF_VAULT) / BPS_DENOMINATOR;
        if (trancheCeiling == 0) revert VaultTooSmallForSchedule();

        uint256 required = (funding + trancheCeiling - 1) / trancheCeiling;
        uint32 milestoneCount =
            required > MIN_PROJECT_MILESTONES ? uint32(required) : MIN_PROJECT_MILESTONES;
        if (milestoneCount > MAX_PROJECT_MILESTONES) revert ExceedsScheduleLimit();
        uint256 perMilestoneCap = (funding + milestoneCount - 1) / milestoneCount;

        prop.executed = true;

        projectId = ++projectCount;
        Project storage project = _projects[projectId];
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
        project.deadline =
            block.timestamp + (uint256(milestoneCount) * MILESTONE_GATING_INTERVAL) + PROJECT_GRACE_PERIOD;
        project.missionDescription = prop.description;

        totalReservedForProjects += funding;

        emit ProjectCreated(
            projectId, proposalId, prop.proposer, funding, milestoneCount, perMilestoneCap, project.deadline
        );
    }

    /* ====================================================================== */
    /*      ROBOT-ENFORCED, TIME-LOCKED, MISSION-BOUND FUND RELEASE           */
    /* ====================================================================== */

    /// @dev Hashes an attestation for inclusion in the MCU-signed digest.
    function _attestationHash(MilestoneAttestation calldata att) private pure returns (bytes32) {
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

    /// @dev The hardcoded mission rules, re-enforced on chain at every single fund release.
    function _enforceMissionRules(MilestoneAttestation calldata att) private pure {
        if (!att.offGridVerified) revert MissionRuleOffGridRequired();
        if (att.solarKwhGenerated == 0) revert MissionRuleSolarRequired();
        if (att.batteryKwhStored == 0) revert MissionRuleBatteryRequired();
        if (att.atmosphericWaterLiters == 0) revert MissionRuleWaterRequired();
        if (att.honeyKgDistributedFree == 0) revert MissionRuleHoneyRequired();
        if (att.hivesInstalled == 0) revert MissionRuleHivesRequired();
        if (!att.landAcquired) revert MissionRuleLandRequired();
        if (!att.equipmentOperational) revert MissionRuleEquipmentRequired();
        if (att.evidenceHash == bytes32(0)) revert MissionRuleEvidenceRequired();
    }

    /**
     * @notice The single path by which OBS can ever leave this vault.
     *
     * @dev Every one of the following must hold:
     *      - the bonding curve has genuinely collected 5,000,000,000 DAI;
     *      - the Roomie robot MCU is commissioned;
     *      - at most one authorization per project per 60 days;
     *      - a valid hybrid PQC and ECDSA authorization from the MCU, which verifies the
     *        operator's biometrics locally before signing;
     *      - the hardcoded mission rules are attested as happening in the real world;
     *      - the tranche is within both the project's per-milestone cap and its anti-dump
     *        tranche ceiling.
     *
     *      Funds go only to the payout recipient the DAO voted on. There is no arbitrary
     *      recipient anywhere in this contract. Checks-Effects-Interactions is observed: the
     *      token transfer is the final statement.
     *
     * @param projectId          Project to release against.
     * @param amount             OBS to release, in wei.
     * @param attestation        The robot's real-world evidence for this tranche.
     * @param pqcPublicKey       The MCU's full PQC public key.
     * @param pqcSignature       The MCU's full PQC signature over the authorization.
     * @param mcuEcdsaSignature  The MCU's 65-byte secp256k1 signature over the hybrid digest.
     * @param otsPreimage        The next link of the MCU's one-time-signature hash chain.
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
        Project storage project = _projects[projectId];
        if (project.id == 0) revert ProjectNotFound();
        if (project.completed) revert ProjectAlreadyCompleted();
        if (project.expired) revert ProjectHasExpired();
        if (block.timestamp > project.deadline) revert ProjectDeadlinePassed();

        uint32 milestoneIndex = project.milestonesCompleted;
        if (milestoneIndex >= project.milestoneCount) revert AllMilestonesCompleted();

        uint256 lastMilestoneTime = project.lastMilestoneTime;
        if (lastMilestoneTime != 0 && block.timestamp < lastMilestoneTime + MILESTONE_GATING_INTERVAL) {
            revert MilestoneLocked();
        }

        if (amount == 0) revert NothingToRelease();
        if (amount > project.perMilestoneCap) revert ExceedsPerMilestoneCap();
        if (amount > project.fundingRemaining) revert ExceedsRemainingFunding();
        if (amount > project.trancheCeiling) revert ExceedsTrancheCap();
        if (amount > totalObsVaultBalance) revert InsufficientVaultBalance();

        _enforceMissionRules(attestation);

        address recipient = project.payoutRecipient;
        bytes32 actionDigest = keccak256(
            abi.encode(
                MILESTONE_TYPEHASH,
                projectId,
                milestoneIndex,
                amount,
                recipient,
                _attestationHash(attestation)
            )
        );
        bytes32 pqcSignatureHash = _verifyHybridPqcAuthorization(
            actionDigest, pqcPublicKey, pqcSignature, mcuEcdsaSignature, otsPreimage
        );

        // ----------------------------- effects ------------------------------
        MissionLedger storage ledger = _missionLedgers[projectId];
        ledger.acresSecured += attestation.acresSecured;
        ledger.hivesInstalled += attestation.hivesInstalled;
        ledger.honeyKgDistributedFree += attestation.honeyKgDistributedFree;
        ledger.atmosphericWaterLiters += attestation.atmosphericWaterLiters;
        ledger.solarKwhGenerated += attestation.solarKwhGenerated;
        ledger.batteryKwhStored += attestation.batteryKwhStored;

        project.lastMilestoneTime = block.timestamp;
        project.milestonesCompleted = milestoneIndex + 1;
        unchecked {
            // All three subtractions are bounded by the checks above.
            project.fundingRemaining -= amount;
            totalObsVaultBalance -= amount;
            totalReservedForProjects -= amount;
        }
        totalObsReleased += amount;

        _accrueBeeFlourishing(attestation.beeFlourishingIndexDelta);

        emit MilestoneAuthorizedByRobot(
            projectId, milestoneIndex, amount, pqcSignatureHash, attestation.evidenceHash, block.timestamp
        );
        emit ProjectFundsWithdrawn(projectId, amount, recipient);

        // --------------------------- interaction ----------------------------
        IERC20(OBS_TOKEN).safeTransfer(recipient, amount);
    }

    /// @dev Accrues robot-attested flourishing progress, capped at the safe optimum.
    function _accrueBeeFlourishing(uint256 delta) private {
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
     * @notice Closes a project once the entirety of it is done.
     * @dev Requires every scheduled milestone to have been delivered and the cumulative mission
     *      ledger to show real acreage, hives, free honey, water, solar and battery. Any
     *      unspent allocation returns to the vault.
     * @param projectId The project to close.
     */
    function completeProject(uint256 projectId) external onlyAdminOrRobot {
        Project storage project = _projects[projectId];
        if (project.id == 0) revert ProjectNotFound();
        if (project.completed) revert ProjectAlreadyCompleted();
        if (project.expired) revert ProjectHasExpired();
        if (project.milestonesCompleted != project.milestoneCount) revert MilestonesIncomplete();

        MissionLedger storage ledger = _missionLedgers[projectId];
        if (ledger.acresSecured < MIN_FLOWERING_ACRES_TARGET) revert MissionOutcomeNotMet();
        if (
            ledger.hivesInstalled == 0 || ledger.honeyKgDistributedFree == 0
                || ledger.atmosphericWaterLiters == 0 || ledger.solarKwhGenerated == 0
                || ledger.batteryKwhStored == 0
        ) {
            revert MissionOutcomeNotMet();
        }

        project.completed = true;

        uint256 unspent = project.fundingRemaining;
        if (unspent != 0) {
            project.fundingRemaining = 0;
            unchecked {
                totalReservedForProjects -= unspent; // returns to the vault, never burned
            }
        }

        emit ProjectCompleted(projectId);
    }

    /**
     * @notice Expires a project that has run past its deadline.
     * @dev Permissionless. Unspent OBS returns to the vault; it is never destroyed and never
     *      becomes withdrawable outside the milestone path.
     * @param projectId The project to expire.
     */
    function checkProjectTimeout(uint256 projectId) external {
        Project storage project = _projects[projectId];
        if (project.id == 0) revert ProjectNotFound();
        if (project.completed) revert ProjectAlreadyCompleted();
        if (project.expired) revert ProjectAlreadyExpired();
        if (block.timestamp <= project.deadline) revert ProjectDeadlineNotReached();

        project.expired = true;

        uint256 returned = project.fundingRemaining;
        if (returned != 0) {
            project.fundingRemaining = 0;
            unchecked {
                totalReservedForProjects -= returned;
            }
        }

        emit ProjectExpired(projectId, returned);
    }

    /* ====================================================================== */
    /*                              VIEW HELPERS                              */
    /* ====================================================================== */

    function getProposalId(uint256 proposalId) external view returns (uint256) { return _proposals[proposalId].id; }
    function getProposalProposer(uint256 proposalId) external view returns (address) { return _proposals[proposalId].proposer; }
    function getProposalPayoutRecipient(uint256 proposalId) external view returns (address) { return _proposals[proposalId].payoutRecipient; }
    function getProposalDescription(uint256 proposalId) external view returns (string memory) { return _proposals[proposalId].description; }
    function getProposalTargetAcres(uint256 proposalId) external view returns (uint256) { return _proposals[proposalId].targetAcresForBees; }
    function getProposalBeeIndex(uint256 proposalId) external view returns (uint256) { return _proposals[proposalId].proposedBeePopulationIndex; }
    function getProposalRequestedFunding(uint256 proposalId) external view returns (uint256) { return _proposals[proposalId].requestedFunding; }
    function getProposalSolarAndBattery(uint256 proposalId) external view returns (bool) { return _proposals[proposalId].solarAndBatteryEquipped; }
    function getProposalAwg(uint256 proposalId) external view returns (bool) { return _proposals[proposalId].atmosphericWaterGenEquipped; }
    function getProposalLandAcquisition(uint256 proposalId) external view returns (bool) { return _proposals[proposalId].landAcquisitionIncluded; }
    function getProposalEquipmentAcquisition(uint256 proposalId) external view returns (bool) { return _proposals[proposalId].equipmentAcquisitionIncluded; }
    function getProposalHoneyProduction(uint256 proposalId) external view returns (bool) { return _proposals[proposalId].honeyProductionAndDistribution; }
    function getProposalForVotes(uint256 proposalId) external view returns (uint256) { return _proposals[proposalId].forVotes; }
    function getProposalAgainstVotes(uint256 proposalId) external view returns (uint256) { return _proposals[proposalId].againstVotes; }
    function getProposalStartTime(uint256 proposalId) external view returns (uint256) { return _proposals[proposalId].startTime; }
    function getProposalEndTime(uint256 proposalId) external view returns (uint256) { return _proposals[proposalId].endTime; }
    function getProposalStartEpoch(uint256 proposalId) external view returns (uint256) { return _proposals[proposalId].startEpoch; }
    function getProposalExecuted(uint256 proposalId) external view returns (bool) { return _proposals[proposalId].executed; }

    /// @notice Whether `voter` has already voted on `proposalId`.
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return _proposals[proposalId].hasVoted[voter];
    }

    function getProjectId(uint256 projectId) external view returns (uint256) { return _projects[projectId].id; }
    function getProjectProposalId(uint256 projectId) external view returns (uint256) { return _projects[projectId].proposalId; }
    function getProjectCreator(uint256 projectId) external view returns (address) { return _projects[projectId].creator; }
    function getProjectPayoutRecipient(uint256 projectId) external view returns (address) { return _projects[projectId].payoutRecipient; }
    function getProjectFundingAmount(uint256 projectId) external view returns (uint256) { return _projects[projectId].fundingAmount; }
    function getProjectFundingRemaining(uint256 projectId) external view returns (uint256) { return _projects[projectId].fundingRemaining; }
    function getProjectPerMilestoneCap(uint256 projectId) external view returns (uint256) { return _projects[projectId].perMilestoneCap; }
    function getProjectTrancheCeiling(uint256 projectId) external view returns (uint256) { return _projects[projectId].trancheCeiling; }
    function getProjectMilestoneCount(uint256 projectId) external view returns (uint32) { return _projects[projectId].milestoneCount; }
    function getProjectMilestonesCompleted(uint256 projectId) external view returns (uint32) { return _projects[projectId].milestonesCompleted; }
    function getProjectStartTime(uint256 projectId) external view returns (uint256) { return _projects[projectId].startTime; }
    function getProjectDeadline(uint256 projectId) external view returns (uint256) { return _projects[projectId].deadline; }
    function getProjectCompleted(uint256 projectId) external view returns (bool) { return _projects[projectId].completed; }
    function getProjectExpired(uint256 projectId) external view returns (bool) { return _projects[projectId].expired; }
    function getProjectLastMilestoneTime(uint256 projectId) external view returns (uint256) { return _projects[projectId].lastMilestoneTime; }
    function getProjectMissionDescription(uint256 projectId) external view returns (string memory) { return _projects[projectId].missionDescription; }

    /// @notice Cumulative real-world delivery attested for a project.
    function getMissionLedger(uint256 projectId) external view returns (MissionLedger memory) {
        return _missionLedgers[projectId];
    }

    /// @notice The next timestamp at which the robot may authorize this project again.
    function nextMilestoneUnlockTime(uint256 projectId) external view returns (uint256) {
        Project storage project = _projects[projectId];
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
}
