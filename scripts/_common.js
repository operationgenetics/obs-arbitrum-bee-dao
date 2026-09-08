const { ethers } = require("ethers");
const { EthereumProvider } = require("@walletconnect/ethereum-provider");
const QRCode = require("qrcode-terminal");
const fs = require("fs");
const path = require("path");
const readline = require("readline");

const ARBITRUM_ONE = 42161;
const ARBITRUM_RPC = "https://arb1.arbitrum.io/rpc";
const ORCHESTRATOR = "0xaF570ce3b32D765b1236635B0f541a7487A1fB8e";
const ROOT = path.join(__dirname, "..");

function artifact() {
    return JSON.parse(fs.readFileSync(path.join(ROOT, "out/BeeHabitatDAO.sol/BeeHabitatDAO.json"), "utf8"));
}

function daoAddress() {
    if (process.env.DAO_ADDRESS) return ethers.getAddress(process.env.DAO_ADDRESS);
    const p = path.join(ROOT, "deployment.json");
    if (!fs.existsSync(p)) {
        throw new Error("No deployment.json found. Deploy first, or set DAO_ADDRESS=0x...");
    }
    return ethers.getAddress(JSON.parse(fs.readFileSync(p, "utf8")).address);
}

function ask(question) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    return new Promise((resolve) => rl.question(question, (a) => { rl.close(); resolve(a.trim()); }));
}

function readOnlyDao() {
    return new ethers.Contract(daoAddress(), artifact().abi, new ethers.JsonRpcProvider(ARBITRUM_RPC, ARBITRUM_ONE));
}

/** Connects MetaMask over WalletConnect and returns a DAO contract bound to the signer. */
async function connectAsOrchestrator(label) {
    const wcProvider = await EthereumProvider.init({
        projectId: "3a8170812b534d0ff9d794f19a901d64",
        chains: [ARBITRUM_ONE],
        optionalChains: [ARBITRUM_ONE],
        rpcMap: { [ARBITRUM_ONE]: ARBITRUM_RPC },
        metadata: {
            name: `BeeHabitatDAO - ${label}`,
            description: label,
            url: "https://obscura.network",
            icons: ["https://avatars.githubusercontent.com/u/37784886"]
        },
        showQrModal: false
    });

    wcProvider.on("display_uri", (uri) => {
        console.log("\nScan this QR code in MetaMask Mobile:\n");
        QRCode.generate(uri, { small: true }, (qr) => console.log(qr));
        console.log(`\nDirect URI:\n${uri}\n`);
    });

    await wcProvider.connect();
    const provider = new ethers.BrowserProvider(wcProvider);
    const network = await provider.getNetwork();
    if (Number(network.chainId) !== ARBITRUM_ONE) {
        throw new Error(`Wrong network: ${network.chainId}, expected Arbitrum One (42161).`);
    }

    const signer = await provider.getSigner();
    const address = await signer.getAddress();
    if (address.toLowerCase() !== ORCHESTRATOR.toLowerCase()) {
        throw new Error(`Connected wallet ${address} is not the orchestrator ${ORCHESTRATOR}. The contract will reject this transaction.`);
    }
    console.log(`Connected as orchestrator: ${address}`);
    return new ethers.Contract(daoAddress(), artifact().abi, signer);
}

module.exports = { ethers, ARBITRUM_ONE, ARBITRUM_RPC, ORCHESTRATOR, ROOT, artifact, daoAddress, ask, readOnlyDao, connectAsOrchestrator };
