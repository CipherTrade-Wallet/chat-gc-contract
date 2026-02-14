const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const contract = process.argv[2] || "contracts/ChatGC.sol";
const outPath = path.join(__dirname, "..", "ChatGC_flat.sol");

const out = execSync(`npx hardhat flatten ${contract}`, {
  encoding: "utf8",
  maxBuffer: 50 * 1024 * 1024,
});
fs.writeFileSync(outPath, out, "utf8");
console.log("Flattened to", path.resolve(outPath));
