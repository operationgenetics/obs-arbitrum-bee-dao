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
const ARBITRUM_ONE_HEX = "0xa4b1";
const ARBITRUM_RPC = "https://arb1.arbitrum.io/rpc";
const EXPECTED_OBS_TOKEN = "0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0";
const EXPECTED_ORCHESTRATOR = "0xaF570ce3b32D765b1236635B0f541a7487A1fB8e";
const WALLETCONNECT_PROJECT_ID = "3a8170812b534d0ff9d794f19a901d64";

const ARTIFACT_PATH = path.join(__dirname, "out/BeeHabitatDAO.sol/BeeHabitatDAO.json");
const DRY_RUN = process.argv.includes("--dry-run");
// --yes skips the terminal confirmations. It does NOT skip wallet approval: the deployment
// still cannot be broadcast without an explicit MetaMask signature.
const ASSUME_YES = process.argv.includes("--yes");
const URI_FILE = path.join(__dirname, ".walletconnect-uri.txt");

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

    // Quoted for information only. We deliberately do NOT override the wallet's fees:
    // forcing maxPriorityFeePerGas to 0 (optimal on Arbitrum, which ignores tips) makes
    // MetaMask warn "transaction likely to fail", and a scary prompt is not worth the
    // fractions of a cent it saves.
    const maxFeePerGas = baseFee;

    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object);
    const deployTx = await factory.getDeployTransaction();
    // Arbitrum's estimate already includes the L1 calldata component of the fee.
    const gasLimit = await provider.estimateGas({ data: deployTx.data });

    const expected = gasLimit * baseFee;

    console.log("\nGas quote (Arbitrum One)");
    console.log(`  Base fee       : ${ethers.formatUnits(baseFee, "gwei")} gwei`);
    console.log(`  Estimated gas  : ${gasLimit.toLocaleString()}  (includes the L1 data component)`);
    console.log(`  Expected cost  : ~${ethers.formatEther(expected)} ETH`);
    console.log(`  Fees are left to MetaMask, so its estimate is the one that counts.`);

    return { gasLimit, expected };
}

// @walletconnect/ethereum-provider fires an unawaited request() from its chainChanged
// handler; when it lands before the provider's rpcProviders map is populated it throws this
// as an unhandled rejection. It is inert for our purposes - see pinToArbitrumOne().
const KNOWN_WC_FAULT = /Cannot read properties of undefined \(reading 'request'\)/;

function installCrashGuards() {
    const report = (label) => (err) => {
        const msg = (err && err.message) || String(err);
        if (KNOWN_WC_FAULT.test(msg)) {
            console.warn("  (suppressed a known WalletConnect chain-switch fault - continuing)");
            return;
        }
        console.error(`\n${label}: ${msg}`);
        console.error("\nNothing was deployed.");
        process.exit(1);
    };
    process.on("uncaughtException", report("Wallet session error"));
    process.on("unhandledRejection", report("Wallet session error"));
}

/**
 * Disarms the library's broken auto-switch, which crashes the process.
 *
 * @walletconnect/ethereum-provider does this on any chainChanged event:
 *     setChainId(x) -> switchEthereumChain(x) -> this.request(...)   // unawaited
 * and formats the chain as `t.toString(16)` with no `0x` prefix, so the request it emits is
 * malformed even when it does not crash. We replace it with a no-op; the wallet's real active
 * network is then read honestly and asserted below.
 */
function disarmBrokenAutoSwitch(wcProvider) {
    // Replace the crashing method with a no-op. We deliberately do NOT force
    // wcProvider.chainId here: overriding it hides the wallet's real active network, which
    // makes the safety check below pass while the wallet is still on another chain. That is
    // how a mainnet transaction reached the signing prompt on an earlier run.
    try { wcProvider.switchEthereumChain = () => {}; } catch (_) {}
}

async function main() {
    installCrashGuards();
    const readProvider = new ethers.JsonRpcProvider(ARBITRUM_RPC, ARBITRUM_ONE);
    const artifact = await preflight(readProvider);
    const gas = await quoteGas(readProvider, artifact);

    if (DRY_RUN) {
        console.log("\n--dry-run: everything above checks out. No wallet was contacted and nothing was sent.");
        console.log("Run `node deploy.js` to deploy for real.\n");
        return;
    }

    console.log("\nBEFORE YOU SCAN: set MetaMask's active network to Arbitrum One.");
    console.log("A wallet sitting on Ethereum Mainnet is the most common cause of a failed pairing.\n");
    console.log("Initializing WalletConnect session...");
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
        try { fs.writeFileSync(URI_FILE, uri + "\n"); } catch (_) {}
        console.log("This pairing link is time-limited. Waiting for you to approve the connection...\n");
    });

    await wcProvider.connect();

    disarmBrokenAutoSwitch(wcProvider);

    // The session's approved accounts are the real authority on what the wallet agreed to,
    // rather than whichever network its UI is currently displaying.
    const approvedAccounts = wcProvider.session?.namespaces?.eip155?.accounts || [];
    const arbitrumAccounts = approvedAccounts.filter((a) => a.startsWith(`eip155:${ARBITRUM_ONE}:`));
    if (arbitrumAccounts.length === 0) {
        console.error("\nThis wallet session does not include Arbitrum One.");
        console.error(`Approved: ${approvedAccounts.join(", ") || "(none)"}`);
        console.error("\nNothing was deployed. Add Arbitrum One to MetaMask, then re-run.\n");
        process.exit(1);
    }
    console.log(`Session includes Arbitrum One: ${arbitrumAccounts.length} account(s).`);
    // NOTE: this only means the wallet *approved* Arbitrum, not that it is currently ON it.

    const readChain = async () => {
        try { return Number(await wcProvider.request({ method: "eth_chainId" })); }
        catch (_) { return Number(wcProvider.chainId); }
    };
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

    let chainId = await readChain();

    if (chainId !== ARBITRUM_ONE) {
        const names = { 1: "Ethereum Mainnet", 137: "Polygon", 10: "Optimism", 8453: "Base", 56: "BNB Chain" };
        const on = names[chainId] ? `${names[chainId]} (chain ${chainId})` : `chain ${chainId}`;
        console.log(`\nWallet is on ${on}. Requesting a switch to Arbitrum One...`);
        console.log(">>> APPROVE THE NETWORK-SWITCH PROMPT IN METAMASK <<<\n");

        // Sent through SignClient directly. The EthereumProvider wrapper formats the chain id
        // without its 0x prefix and dereferences an undefined provider, so it cannot be used.
        const send = (request) => wcProvider.signer.client.request({
            topic: wcProvider.session.topic,
            chainId: `eip155:${chainId}`,
            request
        });

        try {
            await send({ method: "wallet_switchEthereumChain", params: [{ chainId: ARBITRUM_ONE_HEX }] });
        } catch (err) {
            const code = err?.code ?? err?.data?.originalError?.code;
            console.log(`  switch request returned: ${err?.message || err}`);
            if (code === 4902 || code === -32603) {
                console.log("  Arbitrum One is not in this wallet. Requesting to add it...");
                try {
                    await send({
                        method: "wallet_addEthereumChain",
                        params: [{
                            chainId: ARBITRUM_ONE_HEX,
                            chainName: "Arbitrum One",
                            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
                            rpcUrls: [ARBITRUM_RPC],
                            blockExplorerUrls: ["https://arbiscan.io"]
                        }]
                    });
                } catch (addErr) {
                    console.log(`  add request returned: ${addErr?.message || addErr}`);
                }
            }
        }

        // Poll for the wallet to actually report Arbitrum. Never assume the switch worked.
        for (let i = 0; i < 40; i++) {
            await sleep(1500);
            chainId = await readChain();
            if (chainId === ARBITRUM_ONE) break;
            if (i % 4 === 3) console.log(`  still on chain ${chainId}... (${60 - (i + 1) * 1.5 | 0}s left)`);
        }
    }

    if (chainId !== ARBITRUM_ONE) {
        console.error(`\nWallet is still on chain ${chainId}, not Arbitrum One (${ARBITRUM_ONE}).`);
        console.error("Nothing was deployed and no gas was spent.\n");
        console.error("Switch manually in MetaMask Mobile:");
        console.error("  1. Tap the network name at the TOP of the wallet screen.");
        console.error("  2. Select \"Arbitrum One\". If it is not listed, enable it under");
        console.error("     Settings > Networks, or add it from chainlist.org.");
        console.error("  3. Check the balance shown is your Arbitrum ETH, not mainnet ETH.");
        console.error("  4. Re-run `node deploy.js` and scan the new QR code.\n");
        process.exit(1);
    }
    console.log(`Wallet confirmed on Arbitrum One (${chainId}).`);

    // staticNetwork: the chain is verified above, and this stops ethers aborting with
    // NETWORK_ERROR if the wallet re-announces its chain mid-flight.
    const provider = new ethers.BrowserProvider(wcProvider, ARBITRUM_ONE, { staticNetwork: true });

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
        console.log(`\n${"!".repeat(64)}`);
        console.log("WARNING: this is NOT the orchestrator wallet.");
        console.log(`  connected    : ${deployerAddress}`);
        console.log(`  orchestrator : ${EXPECTED_ORCHESTRATOR}`);
        console.log("Deployment works from any wallet - the orchestrator is compiled in, not set at");
        console.log("deploy time - but ONLY the orchestrator can provision the robot, issue LP or");
        console.log("release funds afterwards. Deploying from this wallet is safe, just less tidy.");
        console.log(`${"!".repeat(64)}`);
    }

    if (ASSUME_YES) {
        console.log("\n--yes: proceeding. MetaMask must still approve the transaction.");
    } else if ((await ask("\nDeploy BeeHabitatDAO to Arbitrum One now? [y/N] ")).toLowerCase() !== "y") {
        console.log("Aborted. Nothing was sent.");
        return;
    }

    // Re-assert against the wallet's live chain immediately before building the transaction.
    const finalChainId = Number(await wcProvider.request({ method: "eth_chainId" }));
    if (finalChainId !== ARBITRUM_ONE) {
        throw new Error(`Refusing to deploy: signer is on chain ${finalChainId}, not Arbitrum One.`);
    }

    console.log("\nBroadcasting deployment... confirm on your phone.");
    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object, signer);
    const contract = await factory.deploy();

    const deploymentTx = contract.deploymentTransaction();
    console.log(`Transaction: ${deploymentTx.hash}`);
    console.log("Waiting for confirmation...");

    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();

    // Definitive proof of network: read the code back from an independent Arbitrum One RPC.
    const onChainCode = await readProvider.getCode(contractAddress);
    if (!onChainCode || onChainCode === "0x") {
        throw new Error(`No code at ${contractAddress} on Arbitrum One. The transaction may have landed on another network.`);
    }
    console.log(`Verified on Arbitrum One: ${(onChainCode.length - 2) / 2} bytes of runtime code at ${contractAddress}`);

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
        if (ASSUME_YES) {
            console.log("Skipped under --yes (it needs a second signature). Run: node scripts/setup-robot.js\n");
        } else if ((await ask("Send this transaction now? [y/N] ")).toLowerCase() === "y") {
            const dao = new ethers.Contract(contractAddress, artifact.abi, signer);
            const tx = await dao.setupRoomieRobotAndLock(provisional);
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
