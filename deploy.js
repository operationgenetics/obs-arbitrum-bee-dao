/**
 * Zero-config deployment of BeeHabitatDAO to Arbitrum One.
 *
 *   node deploy.js              deploy for real
 *   node deploy.js --dry-run    preflight + gas quote only, no wallet, no transaction
 *
 * Nothing to fill in. No constructor arguments, no addresses, no environment variables, no
 * edits to this file. Scan the QR code with MetaMask and sign. That is the whole procedure.
 *
 * GAS: Arbitrum One prices a deployment mostly by the L1 calldata needed to post the contract
 * code, plus a small L2 execution component. Two levers are applied here:
 *   1. maxPriorityFeePerGas is set to 0. Arbitrum's sequencer is first-come-first-served and
 *      ignores priority tips, so any tip is money burned for no ordering benefit.
 *   2. maxFeePerGas is pinned just above the current base fee rather than ethers' default 2x
 *      headroom. You are refunded the difference, but a tight cap keeps the wallet's displayed
 *      maximum honest.
 * The script quotes the cost and waits for your confirmation before broadcasting.
 */
const { ethers } = require("ethers");
const { EthereumProvider } = require("@walletconnect/ethereum-provider");
const QRCode = require("qrcode-terminal");
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const ARBITRUM_ONE = 42161;
const ARBITRUM_RPC = "https://arb1.arbitrum.io/rpc";
const EXPECTED_OBS_TOKEN = "0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0";
const EXPECTED_ORCHESTRATOR = "0xaF570ce3b32D765b1236635B0f541a7487A1fB8e";
const WALLETCONNECT_PROJECT_ID = "3a8170812b534d0ff9d794f19a901d64";

const ARTIFACT_PATH = path.join(__dirname, "out/BeeHabitatDAO.sol/BeeHabitatDAO.json");
const DRY_RUN = process.argv.includes("--dry-run");

function ask(question) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    return new Promise((resolve) => rl.question(question, (a) => { rl.close(); resolve(a.trim()); }));
}

/** Verifies the compiled artifact against the live chain before any gas is spent. */
async function preflight(provider) {
    if (!fs.existsSync(ARTIFACT_PATH)) {
        throw new Error(`Artifact not found at ${ARTIFACT_PATH}\nRun \`forge build\` first.`);
    }
    const artifact = JSON.parse(fs.readFileSync(ARTIFACT_PATH, "utf8"));
    const bytecode = artifact.bytecode.object;
    if (!bytecode || bytecode === "0x") throw new Error("Artifact contains no bytecode. Run `forge build`.");

    // The OBS token and orchestrator are compiled in as constants. Prove it, rather than trust it.
    const lower = bytecode.toLowerCase();
    if (!lower.includes(EXPECTED_OBS_TOKEN.slice(2).toLowerCase())) {
        throw new Error(`Bytecode does not reference OBS token ${EXPECTED_OBS_TOKEN}. Refusing to deploy.`);
    }
    if (!lower.includes(EXPECTED_ORCHESTRATOR.slice(2).toLowerCase())) {
        throw new Error(`Bytecode does not reference orchestrator ${EXPECTED_ORCHESTRATOR}. Refusing to deploy.`);
    }

    const obs = new ethers.Contract(
        EXPECTED_OBS_TOKEN,
        [
            "function symbol() view returns (string)",
            "function decimals() view returns (uint8)",
            "function daiReserve() view returns (uint256)"
        ],
        provider
    );
    const [symbol, decimals, reserve, code] = await Promise.all([
        obs.symbol(), obs.decimals(), obs.daiReserve(), provider.getCode(EXPECTED_OBS_TOKEN)
    ]);
    if (code === "0x") throw new Error(`No contract at ${EXPECTED_OBS_TOKEN} on Arbitrum One.`);
    if (symbol !== "OBS") throw new Error(`Token at ${EXPECTED_OBS_TOKEN} reports symbol "${symbol}", expected "OBS".`);

    const deployedSize = (bytecode.length - 2) / 2;
    console.log("Preflight");
    console.log(`  OBS token      : ${EXPECTED_OBS_TOKEN}  (${symbol}, ${decimals} decimals) - live and verified`);
    console.log(`  Curve reserves : ${Number(ethers.formatUnits(reserve, 18)).toLocaleString()} of 5,000,000,000 DAI`);
    console.log(`  Orchestrator   : ${EXPECTED_ORCHESTRATOR}`);
    console.log(`  Creation code  : ${deployedSize.toLocaleString()} bytes - OBS and orchestrator wiring confirmed in bytecode`);
    return artifact;
}

/** Quotes the deployment using Arbitrum-appropriate fee settings. */
async function quoteGas(provider, artifact) {
    const feeData = await provider.getFeeData();
    const baseFee = feeData.gasPrice ?? feeData.maxFeePerGas ?? 0n;

    // Arbitrum ignores priority tips: the sequencer orders first-come-first-served.
    const maxPriorityFeePerGas = 0n;
    // 25% headroom over the current base fee. Unused gas price is refunded on Arbitrum.
    const maxFeePerGas = (baseFee * 125n) / 100n;

    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object);
    const deployTx = await factory.getDeployTransaction();
    // Arbitrum's estimate already includes the L1 calldata component of the fee.
    const gasLimit = await provider.estimateGas({ data: deployTx.data });

    const worstCase = gasLimit * maxFeePerGas;
    const expected = gasLimit * baseFee;

    console.log("\nGas quote (Arbitrum One)");
    console.log(`  Base fee            : ${ethers.formatUnits(baseFee, "gwei")} gwei`);
    console.log(`  Priority fee        : 0 gwei  (Arbitrum is FCFS - a tip buys nothing)`);
    console.log(`  Max fee per gas     : ${ethers.formatUnits(maxFeePerGas, "gwei")} gwei  (+25% headroom, refunded if unused)`);
    console.log(`  Estimated gas       : ${gasLimit.toLocaleString()}  (includes the L1 data component)`);
    console.log(`  Expected cost       : ~${ethers.formatEther(expected)} ETH`);
    console.log(`  Wallet will display : up to ${ethers.formatEther(worstCase)} ETH`);

    return { gasLimit, maxFeePerGas, maxPriorityFeePerGas, expected };
}

async function main() {
    const readProvider = new ethers.JsonRpcProvider(ARBITRUM_RPC, ARBITRUM_ONE);
    const artifact = await preflight(readProvider);
    const gas = await quoteGas(readProvider, artifact);

    if (DRY_RUN) {
        console.log("\n--dry-run: everything above checks out. No wallet was contacted and nothing was sent.");
        console.log("Run `node deploy.js` to deploy for real.\n");
        return;
    }

    console.log("\nInitializing WalletConnect session...");
    const wcProvider = await EthereumProvider.init({
        projectId: WALLETCONNECT_PROJECT_ID,
        chains: [ARBITRUM_ONE],
        optionalChains: [ARBITRUM_ONE],
        rpcMap: { [ARBITRUM_ONE]: ARBITRUM_RPC },
        metadata: {
            name: "BeeHabitatDAO Deployment",
            description: "Deploying BeeHabitatDAO on Arbitrum One",
            url: "https://obscura.network",
            icons: ["https://avatars.githubusercontent.com/u/37784886"]
        },
        showQrModal: false
    });

    wcProvider.on("display_uri", (uri) => {
        console.log("\n" + "=".repeat(64));
        console.log("  Open MetaMask Mobile -> tap the Scan icon (top right) -> scan this:");
        console.log("=".repeat(64) + "\n");
        QRCode.generate(uri, { small: true }, (qr) => console.log(qr));
        console.log("Or paste this URI into MetaMask's WalletConnect field:\n");
        console.log(uri + "\n");
        console.log("Waiting for you to approve the connection...\n");
    });

    await wcProvider.connect();

    const provider = new ethers.BrowserProvider(wcProvider);
    const network = await provider.getNetwork();
    if (Number(network.chainId) !== ARBITRUM_ONE) {
        throw new Error(`Wrong network: connected to chain ${network.chainId}, expected Arbitrum One (42161). Switch networks in MetaMask and retry.`);
    }

    const signer = await provider.getSigner();
    const deployerAddress = await signer.getAddress();
    const balance = await readProvider.getBalance(deployerAddress);

    console.log(`Connected wallet : ${deployerAddress}`);
    console.log(`Balance          : ${ethers.formatEther(balance)} ETH`);

    if (balance < gas.expected) {
        throw new Error(`Insufficient ETH on Arbitrum One. Need roughly ${ethers.formatEther(gas.expected)} ETH, wallet holds ${ethers.formatEther(balance)} ETH.`);
    }

    const isOrchestrator = deployerAddress.toLowerCase() === EXPECTED_ORCHESTRATOR.toLowerCase();
    if (!isOrchestrator) {
        console.log(`\nNote: this is not the orchestrator wallet (${EXPECTED_ORCHESTRATOR}).`);
        console.log("      Deployment still works, because the orchestrator is compiled in rather than");
        console.log("      set at deploy time. But only that wallet can provision the robot afterwards.");
    }

    if ((await ask("\nDeploy BeeHabitatDAO to Arbitrum One now? [y/N] ")).toLowerCase() !== "y") {
        console.log("Aborted. Nothing was sent.");
        return;
    }

    console.log("\nBroadcasting deployment... confirm on your phone.");
    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object, signer);
    const contract = await factory.deploy({
        gasLimit: gas.gasLimit,
        maxFeePerGas: gas.maxFeePerGas,
        maxPriorityFeePerGas: gas.maxPriorityFeePerGas
    });

    const deploymentTx = contract.deploymentTransaction();
    console.log(`Transaction: ${deploymentTx.hash}`);
    console.log("Waiting for confirmation...");

    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();
    const receipt = await readProvider.getTransactionReceipt(deploymentTx.hash);
    const paid = receipt ? receipt.gasUsed * receipt.gasPrice : 0n;

    console.log("\n" + "=".repeat(64));
    console.log("  Deployment successful");
    console.log("=".repeat(64));
    console.log(`  BeeHabitatDAO : ${contractAddress}`);
    console.log(`  Arbiscan      : https://arbiscan.io/address/${contractAddress}`);
    if (receipt) {
        console.log(`  Gas used      : ${receipt.gasUsed.toLocaleString()}`);
        console.log(`  Actually paid : ${ethers.formatEther(paid)} ETH`);
    }
    console.log("=".repeat(64) + "\n");

    fs.writeFileSync(
        path.join(__dirname, "deployment.json"),
        JSON.stringify({
            network: "arbitrum-one",
            chainId: ARBITRUM_ONE,
            address: contractAddress,
            obsToken: EXPECTED_OBS_TOKEN,
            orchestrator: EXPECTED_ORCHESTRATOR,
            deployer: deployerAddress,
            transactionHash: deploymentTx.hash,
            deployedAt: new Date().toISOString()
        }, null, 2) + "\n"
    );
    console.log("Wrote deployment.json\n");

    console.log("Verify the source on Arbiscan with:");
    console.log(`  forge verify-contract ${contractAddress} contracts/BeeHabitatDAO.sol:BeeHabitatDAO \\`);
    console.log(`    --chain arbitrum --watch --etherscan-api-key <KEY>\n`);

    if (isOrchestrator) {
        const provisional = ethers.keccak256(
            ethers.toUtf8Bytes(`BeeHabitatDAO:ROOMIE_PROVISIONAL:${contractAddress.toLowerCase()}`)
        );
        console.log("Step 2 - anchor the Roomie robot slot now (provisional; spending stays impossible):");
        console.log(`  setupRoomieRobotAndLock(${provisional})`);
        if ((await ask("Send this transaction now? [y/N] ")).toLowerCase() === "y") {
            const dao = new ethers.Contract(contractAddress, artifact.abi, signer);
            const tx = await dao.setupRoomieRobotAndLock(provisional, { maxPriorityFeePerGas: 0n });
            console.log(`Transaction: ${tx.hash}`);
            await tx.wait();
            console.log("Roomie robot slot provisioned.\n");
        } else {
            console.log("Skipped. Run it later with: node scripts/setup-robot.js\n");
        }
    }

    console.log("When the Roomie robot and its PQC MCU arrive:");
    console.log("  1. node scripts/generate-ots-chain.js 1024");
    console.log("  2. node scripts/commission-robot.js      - bind the real PQC key, MCU signer and OTS chain");
    console.log("  3. node scripts/revoke-immutability.js   - FINAL: freeze the configuration forever\n");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("\nDeployment failed:", error.message || error);
        process.exit(1);
    });
