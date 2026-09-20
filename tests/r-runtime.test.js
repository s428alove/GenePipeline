const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { discoverR, probeRscript } = require("../decision_ui/api/runtime/r-discovery");
const { selectR } = require("../decision_ui/api/runtime/r-selection");
const { preflightR } = require("../decision_ui/api/runtime/r-preflight");

test("discovery uses actual probe version, keeps unusable candidates, and merges PATH duplicates", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "genepipeline-r-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const paths = ["R-99.0/bin", "unusual-name/bin/x64", "broken/bin/i386"];
  paths.forEach((directory) => {
    fs.mkdirSync(path.join(root, directory), { recursive: true });
    fs.writeFileSync(path.join(root, directory, "Rscript.exe"), "fixture");
  });
  let probes = 0;
  const result = discoverR({
    platform: "win32", pathValue: `"${path.join(root, paths[0])}";${path.join(root, paths[0])}`,
    installationRoots: [root],
    probe: (file) => {
      probes++;
      return file.includes("broken")
        ? { version: null, executableStatus: "unusable", error: { code: "EACCES" } }
        : { version: file.includes("unusual-name") ? "4.5.2" : "4.4.3", executableStatus: "usable", error: null };
    }
  });
  assert.equal(probes, 3);
  assert.equal(result.detected, true);
  assert.equal(result.candidates[0].version, "4.4.3");
  assert.deepEqual(result.candidates[0].sources, ["PATH", "installation-directory"]);
  assert.equal(selectR(result).selected.version, "4.5.2");
  assert.equal(result.candidates.filter((c) => c.executableStatus === "unusable").length, 1);
});

function candidate(version, source = "installation-directory") {
  return { version, executableStatus: "usable", sources: [source] };
}

test("selection prefers highest validated, permits newer best-effort, blocks old R", () => {
  const policy = { ...require("../decision_ui/api/runtime/r-compatibility").registry,
    validated: { "4.5.2": "test evidence", "4.5.3": "test evidence" } };
  const candidates = [candidate("4.9.0"), candidate("4.4.3", "PATH"), candidate("4.5.2")];
  assert.equal(selectR({ candidates }, policy).selected.version, "4.5.2");
  assert.equal(selectR({ candidates: [...candidates, candidate("4.5.3")] }, policy).selected.version, "4.5.3");
  assert.equal(selectR({ candidates: [candidate("4.5.2"), candidate("4.5.3")] }).selected.version, "4.5.3");
  assert.equal(selectR({ candidates: candidates.slice(0, 2) }, policy).selected.version, "4.9.0");
  assert.equal(selectR({ candidates: [candidate("4.3.3"), candidate("4.3.3")] }, policy).error.code, "R_UNSUPPORTED");
  assert.equal(selectR({ candidates: [candidate("4.3.3"), candidate("4.9.0")] }, policy).compatibility.status, "unvalidated");
  assert.equal(selectR({ candidates: [] }).error.code, "R_NOT_AVAILABLE");
});

test("probe reports nonzero exits, malformed output, timeout and missing executables", () => {
  assert.equal(probeRscript("fixture", { run: () => ({ status: 0, stdout: "not R" }) }).error.code, "INVALID_R_VERSION");
  assert.equal(probeRscript("fixture", { run: () => ({ status: 1, stderr: "broken" }) }).error.code, "R_PROBE_FAILED");
  const timed = probeRscript(process.execPath, {
    timeout: 100,
    run: (file, args, options) => require("node:child_process").spawnSync(file, ["-e", "setInterval(() => {}, 1000)"], options)
  });
  assert.equal(timed.error.code, "ETIMEDOUT");
  assert.equal(probeRscript(path.join(os.tmpdir(), "genepipeline-absent", "Rscript.exe")).error.code, "ENOENT");
});

test("empty discovery returns a clear preflight failure", () => {
  const result = preflightR({ discover: () => discoverR({ pathValue: "", installationRoots: [] }) });
  assert.equal(result.ok, false);
  assert.equal(result.discovery.detected, false);
  assert.equal(result.error.code, "R_NOT_AVAILABLE");
  assert.match(result.error.message, /install R/i);
});

test("local Windows R discovery and a second real R execution (Cases A/B)", { skip: process.platform !== "win32" }, () => {
  const result = preflightR();
  assert.equal(result.ok, true, JSON.stringify(result));
  const version = execFileSync(result.selected.executablePath,
    ["--vanilla", "-e", "cat(as.character(getRversion()))"], { encoding: "utf8", windowsHide: true, timeout: 5000 });
  assert.equal(version.trim(), result.selected.version);
});
