import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

if (process.platform === "win32") {
  console.log("linux shell script checks skipped on Windows");
  process.exit(0);
}

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scripts = ["start.sh", "stop.sh", "tunnel.sh", "openai-tunnel.sh"];

for (const script of scripts) {
  const file = path.join(repoRoot, script);
  const syntax = spawnSync("bash", ["-n", file], { encoding: "utf8" });
  assert.equal(syntax.status, 0, `${script} has invalid bash syntax:\n${syntax.stderr}`);
  const help = spawnSync("bash", [file, "--help"], { encoding: "utf8" });
  assert.equal(help.status, 0, `${script} --help failed:\n${help.stderr}`);
  assert.match(help.stdout, /Usage:/, `${script} --help should print usage`);
}
console.log("Linux shell scripts PASS");
