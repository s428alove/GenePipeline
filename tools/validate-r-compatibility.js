// One target per invocation. Discovery must observe the real requested version.
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { preflightR } = require("../decision_ui/api/runtime/r-preflight");
const { createPackageEnvironment, PROJECT_ROOT } = require("../decision_ui/api/runtime/package-environment");
const { runSmoke } = require("./smoke-environment");
async function main() {
  const version = process.argv[2];
  if (!/^\d+\.\d+\.\d+$/.test(version || "")) throw new Error("Usage: node tools/validate-r-compatibility.js <R-version>");
  process.env.NODE_ENV = "test";
  process.env.GENEPIPELINE_TEST_R_VERSION = version;
  // Optional maintainer-only isolated runtime, still discovered and really probed.
  const binFlag = process.argv.indexOf("--r-bin");
  if (binFlag !== -1) {
    if (!process.argv[binFlag + 1]) throw new Error("--r-bin requires a directory");
    process.env.PATH = path.resolve(process.argv[binFlag + 1]) + path.delimiter + process.env.PATH;
  }
  const runtime = preflightR();
  if (!runtime.ok || runtime.selected.version !== version) throw new Error(JSON.stringify(runtime));
  const evidence = path.join(PROJECT_ROOT, "tmp/compatibility", version);
  fs.mkdirSync(evidence, { recursive: true });
  // Clear old completion evidence, so a failed rerun cannot appear to pass.
  for (const name of ["suite.json", "report.json"]) fs.rmSync(path.join(evidence, name), { force: true });
  const ready = await createPackageEnvironment({ onState: (s) => console.log(`[validation ${version}] ${s.state}`) }).setup(runtime);
  if (!ready.ok) throw new Error(JSON.stringify(ready));
  const tests = spawnSync(process.execPath, ["--test", "tests/*.test.js"], { cwd: PROJECT_ROOT, env: process.env,
    encoding: "utf8", windowsHide: true, timeout: 180000, maxBuffer: 8 * 1024 * 1024 });
  const testOutput = (tests.stdout || "") + (tests.stderr || "");
  fs.writeFileSync(path.join(evidence, "tests.tap"), testOutput);
  console.log(testOutput);
  if (tests.status !== 0 || !/^# fail 0$/m.test(testOutput) || !/^# skipped 0$/m.test(testOutput)) throw new Error("Regression tests failed or skipped");
  const report = await runSmoke({ compatibilityMode: true, runtime });
  fs.writeFileSync(path.join(evidence, "suite.json"), JSON.stringify({ ok: true, version,
    timestamp: new Date().toISOString(), node: process.version, platform: process.platform,
    fixtureHash: report.fixtureHash, lockHash: report.lockHash, tests: { exitCode: tests.status, skipped: 0 },
    bootstrap: report.states.includes("bootstrapping"), restore: report.states.includes("restoring"),
    contracts: ["V0", "Decision", "V1 full", "V1 thresholds-only", "significant ID set", "fixture integrity"] }, null, 2));
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
