# BeeHabitatDAO — Off-Grid Bee Habitat DAO & Vault (Arbitrum One)

An immutable, zero-config DAO and OBS vault. Funds stay locked until the Obscura bonding curve
genuinely collects **5,000,000,000 DAI**, after which they can only be spent — slowly, in
60-day tranches — by a Roomie humanoid robot holding a hybrid post-quantum credential, against
hardcoded mission rules that must be attested as actually happening in the real world.

- **OBS token:** [`0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0`](https://arbiscan.io/token/0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0) (Obscura, OBS, 18 decimals)
- **Config authority / orchestrator:** `0xaF570ce3b32D765b1236635B0f541a7487A1fB8e`
- **Network:** Arbitrum One (42161)

Both addresses are compiled in as `constant`. There is no constructor argument, no initializer,
no proxy, no owner, no pause switch, and no upgrade path.

---

## The mission, hardcoded

> Off-grid indoor bee habitats with atmospheric water generation, solar generation and battery
> storage; honey farmed and given away free; land and equipment acquired and maintained
> indefinitely until the optimal bee flourishing index is reached.

These are not comments. Every one is a `require` that runs twice: once when a proposal is
created, and again at **every single fund release**, against a robot-signed attestation.

| Rule | Enforced at proposal | Enforced at every release |
|---|---|---|
| Site fully off-grid | — | `offGridVerified == true` |
| Solar generation | `solarAndBatteryEquipped` | `solarKwhGenerated > 0` |
| Battery storage | `solarAndBatteryEquipped` | `batteryKwhStored > 0` |
| Atmospheric water generation | `atmosphericWaterGenEquipped` | `atmosphericWaterLiters > 0` |
| Free honey distribution | `honeyProductionAndDistribution` | `honeyKgDistributedFree > 0` |
| Indoor hives | — | `hivesInstalled > 0` |
| Land acquisition | `landAcquisitionIncluded` | `landAcquired == true` |
| Maintenance equipment | `equipmentAcquisitionIncluded` | `equipmentOperational == true` |
| Robot evidence bundle | — | `evidenceHash != 0` |
| ≥ 20 flowering acres | `targetAcresForBees >= 20` | cumulative check at completion |
| Bee index within safe capacity | `<= 500,000` | index capped at the optimum |

A project cannot be marked complete until every milestone is delivered *and* the cumulative
ledger shows real acreage, hives, free honey, water, solar and battery.

---

## Governance

| Parameter | Value |
|---|---|
| LP issuance | 100 LP per member per month, cumulative — not per call |
| LP expiry | End of the 30-day epoch. Never carried forward. |
| Proposal threshold | 50 unexpired LP |
| Vote weight | 1 LP = 1 vote |
| Voting period | 30 days |
| Quorum | 10% of the epoch's live LP supply |

Funding is fixed by the proposal the DAO voted on. `executeProposal(proposalId)` takes no amount
argument, so an executor can never choose the number. The payout recipient is likewise fixed at
proposal time — there is no arbitrary-recipient withdrawal function anywhere in the contract.

---

## Anti-dump: money moves slowly or not at all

| Guard | Value |
|---|---|
| Max share of the vault per project | 20% of unreserved balance |
| Max per 60-day tranche | 2.5% of vault balance, fixed at approval |
| Minimum tranches per project | 6 (≥ 12 months) |
| Robot authorization cadence | once per project per 60 days |
| Project deadline | `milestoneCount × 60 days + 90 days` grace |

The tranche count is derived mathematically: `max(6, ceil(funding / trancheCeiling))`. A project
therefore *cannot* be finished faster than its schedule allows, and a maximally-sized project is
stretched across eight tranches, over more than a year. Timed-out projects return unspent OBS to
the vault — funds are never burned and never become withdrawable outside the milestone path.

---

## Hybrid post-quantum security

Forging an authorization requires breaking **both** legs. Breaking one is not enough.

| Leg | Mechanism | Survives a quantum adversary |
|---|---|---|
| 1 — identity | full PQC public key must hash to the on-chain commitment | yes (keccak256 pre-image) |
| 2 — authorization | reveal the next link of the MCU's keccak256 OTS hash chain | yes (keccak256 pre-image) |
| 3 — anchoring | full PQC signature hashed and bound into the digest | yes |
| 4 — classical | secp256k1 ECDSA over a domain-separated digest | no — that is why legs 1–3 exist |

The digest binds chain id, contract address, project id, **milestone index**, amount, recipient
and the full attestation. Change any byte and verification fails. Leg 2 makes every
authorization single-use and forward-secure: the revealed link becomes the new tip, so a replay
no longer hashes to it.

**Biometrics never touch the chain.** Facial, voice and fingerprint templates stay hard-locked
inside the MCU secure element on the robot. The MCU checks them locally and only then produces
the signature. On chain there is a public key commitment and nothing else.

The one-time-signature chain is built as `s_i = keccak256(s_{i-1})`, publishing `s_N`. Reveals
run backwards: `s_{N-1}`, `s_{N-2}`, … Its length is the hard ceiling on how many releases the
credential can ever authorize.

---

## The vault unlock is trustless

```solidity
function checkAndUnlockVault() external   // no arguments at all
```

It reads `daiReserve()` directly from the OBS token on Arbitrum One. No oracle, no relayer, no
caller-supplied figure, no off-chain feed — fully off-grid. If the getter is ever unavailable
the read returns 0 and the unlock **fails closed**. Not even the orchestrator can unlock an
under-funded curve.

---

## Deploying

```bash
forge build
node deploy.js
```

Nothing to fill in: no constructor arguments, no addresses, no environment variables, no edits
to the deploy script. It runs a preflight against Arbitrum One (confirming the OBS token and
that the compiled bytecode really references it), shows a QR code, and deploys when you sign in
MetaMask. If you connect with the orchestrator wallet it will also offer the immediate
`setupRoomieRobotAndLock` provisioning transaction. The address is written to `deployment.json`.

## Operating

| Script | When |
|---|---|
| `node scripts/status.js` | any time — read-only overview |
| `node scripts/setup-robot.js` | day one, if you skipped it during deploy |
| `node scripts/generate-ots-chain.js [length]` | before commissioning — derives the publishable chain tip |
| `node scripts/commission-robot.js` | when the robot and MCU physically arrive |
| `node scripts/authorize-milestone.js` | each 60-day release |
| `node scripts/revoke-immutability.js` | **final** — freezes configuration forever |

### Robot lifecycle, in order

1. **Deploy.** Configuration is updatable.
2. **`setupRoomieRobotAndLock(hash)`** — anchors the robot slot with a provisional commitment.
   This deliberately does *not* enable spending.
3. **`commissionRoomieRobot(pqcKeyHash, mcuSigner, otsChainTip, otsLength)`** — when the hardware
   lands, bind the real credential. Rotate as many times as you need.
4. **`revokeAndUpdateImmutability()`** — irreversible. The PQC key, MCU signer and OTS chain can
   never be changed again, by anyone, including the orchestrator.

> **Order matters.** Revoking before commissioning permanently bricks every fund release.
> `scripts/revoke-immutability.js` refuses to run in that state, and
> `test_RevokeBeforeCommissioningPermanentlyBricksSpending` documents it.

Freezing configuration does not brick the DAO: proposals, voting, milestone releases and project
completion all keep working — under the now-permanent credential.

### Releasing a milestone

```bash
# 1. Print the digest for the MCU to sign — no transaction is sent.
PROJECT_ID=1 AMOUNT=1000 ATTESTATION_FILE=./attestation.json \
PQC_PUBKEY_FILE=./roomie-pqc-pubkey.bin PQC_SIGNATURE_FILE=./roomie.sig \
OTS_PREIMAGE=0x... DRY_RUN=1 node scripts/authorize-milestone.js

# 2. The MCU signs it under biometric consent, then submit.
... MCU_ECDSA_SIGNATURE=0x... node scripts/authorize-milestone.js
```

The script re-checks every mission rule, the OTS tip, the PQC key commitment and the recovered
signer locally before it will send anything.

---

## Tests

```bash
forge test
```

75 tests across three suites: core governance and wiring, hybrid-PQC and fund release, and a
full end-to-end audit with fuzzing. Coverage includes the complete six-milestone lifecycle to
completion, quorum enforcement, timeout refunds, vault-accounting invariants, and negative cases
for every leg of the hybrid credential — wrong PQC key, wrong or replayed OTS link,
classically-sized PQC signature, wrong ECDSA signer, and tampering with the amount or the
attestation after signing.
