/**
 * Zero-config deployment of BeeHabitatDAO to Arbitrum One.
 *
 *   node deploy.js
 *
 * Nothing to fill in. No constructor arguments, no addresses, no environment variables.
 * Scan the QR code with MetaMask (WalletConnect) and sign. That is the whole procedure.
 *
 * If the wallet you connect is the hardcoded orchestrator, this script will also offer the
 * immediate `setupRoomieRobotAndLock` provisioning transaction so the robot slot is anchored
 * the moment the contract exists.
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

const ARTIFACT_PATH = path.join(__dirname, "out/BeeHabitatDAO.sol/BeeHabitatDAO.json");

function ask(question) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    return new Promise((resolve) => rl.question(question, (a) => { rl.close(); resolve(a.trim()); }));
}

async function preflight() {
    if (!fs.existsSync(ARTIFACT_PATH)) {
        throw new Error(`Artifact not found at ${ARTIFACT_PATH}\nRun \`forge build\` first.`);
    }
    const artifact = JSON.parse(fs.readFileSync(ARTIFACT_PATH, "utf8"));

    // The wiring is compiled in as constants; verify it against the live chain before spending gas.
    const readOnly = new ethers.JsonRpcProvider(ARBITRUM_RPC, ARBITRUM_ONE);
    const obs = new ethers.Contract(
        EXPECTED_OBS_TOKEN,
        ["function symbol() view returns (string)", "function daiReserve() view returns (uint256)"],
        readOnly
    );
    const [symbol, reserve] = await Promise.all([obs.symbol(), obs.daiReserve()]);

    const bytecode = artifact.bytecode.object.toLowerCase();
    const needle = EXPECTED_OBS_TOKEN.slice(2).toLowerCase();
    if (!bytecode.includes(needle)) {
        throw new Error(`Compiled bytecode does not reference OBS token ${EXPECTED_OBS_TOKEN}. Refusing to deploy.`);
    }

    console.log("Preflight");
    console.log(`  OBS token       : ${EXPECTED_OBS_TOKEN} (${symbol}) - verified on Arbitrum One`);
    console.log(`  Curve reserves  : ${ethers.formatUnits(reserve, 18)} DAI of 5,000,000,000 DAI`);
    console.log(`  Orchestrator    : ${EXPECTED_ORCHESTRATOR}`);
    console.log(`  Bytecode        : ${(bytecode.length - 2) / 2} bytes, OBS wiring confirmed\n`);

    return artifact;
}

async function main() {
    const artifact = await preflight();

    console.log("Initializing WalletConnect session...");
    const wcProvider = await EthereumProvider.init({
        projectId: "3a8170812b534d0ff9d794f19a901d64",
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
        console.log("\nScan this QR code in MetaMask Mobile (Scan icon, top right):\n");
        QRCode.generate(uri, { small: true }, (qr) => console.log(qr));
        console.log(`\nDirect URI:\n${uri}\n`);
    });

    console.log("Connecting to WalletConnect relay...");
    await wcProvider.connect();

    const provider = new ethers.BrowserProvider(wcProvider);
    const network = await provider.getNetwork();
    if (Number(network.chainId) !== ARBITRUM_ONE) {
        throw new Error(`Wrong network: connected to chain ${network.chainId}, expected Arbitrum One (42161).`);
    }

    const signer = await provider.getSigner();
    const deployerAddress = await signer.getAddress();
    console.log(`\nConnected wallet: ${deployerAddress}`);

    const isOrchestrator = deployerAddress.toLowerCase() === EXPECTED_ORCHESTRATOR.toLowerCase();
    if (!isOrchestrator) {
        console.log(`Note: this wallet is not the hardcoded orchestrator (${EXPECTED_ORCHESTRATOR}).`);
        console.log("      Deployment still works - the orchestrator is compiled in, not set at deploy time.");
    }

    console.log("\nBroadcasting deployment... confirm on your phone.");
    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object, signer);
    const contract = await factory.deploy();
    console.log(`Transaction: ${contract.deploymentTransaction().hash}`);

    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();

    console.log("\n==========================================");
    console.log("Deployment successful");
    console.log(`BeeHabitatDAO: ${contractAddress}`);
    console.log(`Arbiscan:      https://arbiscan.io/address/${contractAddress}`);
    console.log("==========================================\n");

    fs.writeFileSync(
        path.join(__dirname, "deployment.json"),
        JSON.stringify(
            { network: "arbitrum-one", chainId: ARBITRUM_ONE, address: contractAddress, obsToken: EXPECTED_OBS_TOKEN, orchestrator: EXPECTED_ORCHESTRATOR, deployer: deployerAddress, deployedAt: new Date().toISOString() },
            null, 2
        ) + "\n"
    );
    console.log("Wrote deployment.json\n");

    if (isOrchestrator) {
        const provisional = ethers.keccak256(
            ethers.toUtf8Bytes(`BeeHabitatDAO:ROOMIE_PROVISIONAL:${contractAddress.toLowerCase()}`)
        );
        console.log("Step 2 - anchor the Roomie robot slot now (provisional; spending stays impossible):");
        console.log(`  setupRoomieRobotAndLock(${provisional})`);
        const answer = await ask("Send this transaction now? [y/N] ");
        if (answer.toLowerCase() === "y") {
            const dao = new ethers.Contract(contractAddress, artifact.abi, signer);
            const tx = await dao.setupRoomieRobotAndLock(provisional);
            console.log(`Transaction: ${tx.hash}`);
            await tx.wait();
            console.log("Roomie robot slot provisioned.\n");
        } else {
            console.log("Skipped. Run it later with: node scripts/setup-robot.js\n");
        }
    }

    console.log("Next, when the Roomie robot and its PQC MCU arrive:");
    console.log("  1. node scripts/commission-robot.js   - bind the real PQC key, MCU signer and OTS chain");
    console.log("  2. node scripts/revoke-immutability.js - FINAL: freeze the configuration forever\n");

    process.exit(0);
}

main().catch((error) => {
    console.error("Deployment failed:", error.message || error);
    process.exit(1);
});
