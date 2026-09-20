// Explicit integration smoke; never run automatically by application startup.
// Uses copied demo inputs/decisions and a fresh isolated environment. Network is
// needed to exercise first-time renv bootstrap. Installed package cache is reused.
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const { once } = require("node:events");
const { createApp } = require("../decision_ui/api/server");
const { createPackageEnvironment, PROJECT_ROOT } = require("../decision_ui/api/runtime/package-environment");
const { environmentFixture } = require("../tests/environment-fixture");
const { preflightR } = require("../decision_ui/api/runtime/r-preflight");
const contracts = require("../tests/compatibility-contracts");

async function repairSmoke(project) {
  const parent = path.resolve(PROJECT_ROOT, "tmp/phase2-smoke") + path.sep;
  project = path.resolve(project);
  if (!project.startsWith(parent) || !fs.existsSync(path.join(project, "smoke-report.json"))) {
    throw new Error("Repair smoke only accepts a completed, isolated smoke project.");
  }
  const runtime = preflightR();
  const manager = createPackageEnvironment({ project, onState: (s) => console.log(`[repair smoke] ${s.state}: ${s.error?.message || ""}`) });
  const ready = await manager.inspect(runtime);
  assert.equal(ready.ok, true, JSON.stringify(ready));
  const target = path.join(ready.library, "optparse");
  const description = fs.readFileSync(path.join(target, "DESCRIPTION"));
  assert.equal(fs.lstatSync(target).isSymbolicLink(), true);
  fs.unlinkSync(target); // Remove only this fixture's junction, never its cache target.
  fs.mkdirSync(target);
  fs.writeFileSync(path.join(target, "DESCRIPTION"), description);
  const broken = await manager.inspect(runtime);
  assert.equal(broken.ok, false);
  assert.equal(broken.error.code, "PACKAGE_VALIDATION_FAILED");
  assert.deepEqual(broken.mismatches, []);
  const repaired = await manager.setup(runtime);
  assert.equal(repaired.ok, true, JSON.stringify(repaired));
  const report = JSON.parse(fs.readFileSync(path.join(project, "smoke-report.json")));
  report.brokenPackageRepair = { ok: true, rejectedBeforeRepair: true, synchronized: repaired.synchronized, logFile: repaired.logFile };
  fs.writeFileSync(path.join(project, "smoke-report.json"), JSON.stringify(report, null, 2));
  console.log("Broken package repair smoke: PASS");
}

async function runSmoke({ compatibilityMode = false, runtime = preflightR() } = {}) {
  assert.equal(runtime.ok, true, JSON.stringify(runtime));
  const frozen = contracts.FIXTURE;
  const fixtureHash = compatibilityMode ? contracts.integrity() : null;
  const config = compatibilityMode ? contracts.json(path.join(frozen, "config/parameters.json")) : null;
  const gse = "GSE10288";
  const fixture = environmentFixture({ prefix: "demo-", cache: true, bootstrap: false });
  console.log(`Isolated smoke project: ${fixture.project}`);
  for (const directory of ["V0_data_ingest", "decision_layer", "V1_analysis"]) {
    fs.cpSync(path.join(PROJECT_ROOT, directory), path.join(fixture.project, directory), { recursive: true });
  }
  fs.cpSync(compatibilityMode ? path.join(frozen, "input") : path.join(PROJECT_ROOT, "data_raw", gse), path.join(fixture.project, "data_raw", gse), { recursive: true });
  const out = `data_processed/${gse}`;
  fs.mkdirSync(path.join(fixture.project, out), { recursive: true });
  const decisionName = "sample_metadata_decision.tsv";
  const sourceDecision = compatibilityMode ? path.join(frozen, "decision", decisionName) : path.join(PROJECT_ROOT, out, decisionName);
  fs.copyFileSync(sourceDecision, path.join(fixture.project, out, decisionName));
  const originalDecision = fs.readFileSync(sourceDecision, "utf8");
  // Use the existing reviewed demo threshold, without changing source data/settings.
  const threshold = compatibilityMode ? config.v0.max_missing_gene_fraction : JSON.parse(fs.readFileSync(path.join(PROJECT_ROOT, out, "_engineering/missingness_gate.json"))).configured_threshold;
  const states = [];
  const environment = createPackageEnvironment({ project: fixture.project, onState: (s) => {
    states.push(s.state); console.log(`[smoke environment] ${s.state}: ${s.message || s.error?.message || ""}`);
  } });
  const app = createApp({ projectRoot: fixture.project, environment, preflight: () => runtime });
  const ready = await app.locals.setupEnvironment();
  assert.equal(ready.ok, true, JSON.stringify(ready));
  assert.ok(states.includes("bootstrapping"));
  assert.ok(states.includes("restoring"));
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  const results = [];
  const comparison = {};
  async function post(route, body) {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/${route}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
    });
    const result = await response.json();
    fs.writeFileSync(path.join(fixture.project, route.replaceAll("/", "-") + ".json"), JSON.stringify(result, null, 2));
    assert.equal(response.status, 200, `${route}: ${JSON.stringify(result)}`);
    results.push({ route, status: response.status, message: result.message });
    console.log(`[smoke] ${route}: PASS`);
    return result;
  }
  try {
    const v0 = await post("v0/run", { gse, max_missing_gene_fraction: threshold });
    if (compatibilityMode) {
      comparison.v0 = contracts.validateV0(fixture.project);
      // Preserve actual V0 results before using a fixed substrate for V1. This
      // separates V0 drift from V1 statistics instead of allowing cancellation.
      fs.copyFileSync(path.join(fixture.project, out, "expression_gene_log.tsv"), path.join(fixture.project, "v0-expression.tsv"));
      fs.copyFileSync(path.join(frozen, "expected/expression_gene_log.tsv"), path.join(fixture.project, out, "expression_gene_log.tsv"));
    }
    const candidates = await post("project/load", { gse, out });
    const rows = candidates.rows.map((row) => ({ ...row,
      include_edit: row.include_existing,
      group_label_edit: row.group_label_existing,
      case_control_edit: row.case_control_existing,
      reason_exclude_edit: row.reason_exclude_existing === "NA" ? "" : row.reason_exclude_existing
    }));
    const decision = { gse, out, rows, datasetSignature: candidates.loaded.datasetSignature };
    await post("decision/save", decision);
    await post("decision/export-and-merge", decision);
    await post("decision/run-validation", { gse, out });
    if (compatibilityMode) comparison.decision = contracts.validateDecision(fixture.project);
    await post("v1/run", { gse, run_mode: "full", ...(config?.v1 || {}), debug: true });
    if (compatibilityMode) comparison.v1 = contracts.validateV1(fixture.project);
    await post("v1/run", { gse, run_mode: "thresholds_only", padj_cutoff: 0.1, lfc_cutoff: 0.5, debug: true });
    if (compatibilityMode) comparison.thresholdsOnly = contracts.validateV1(fixture.project);
    assert.equal(fs.readFileSync(sourceDecision, "utf8"), originalDecision);
    const report = { ok: true, gse, threshold, project: fixture.project, environment: ready,
      states, v0Gate: v0.data.gate, sampleCount: candidates.n_samples, results,
      runtime, fixtureHash, lockHash: contracts.sha256(path.join(PROJECT_ROOT, "renv.lock")), comparison };
    fs.writeFileSync(path.join(fixture.project, "smoke-report.json"), JSON.stringify(report, null, 2));
    if (compatibilityMode) {
      assert.equal(contracts.integrity(), fixtureHash, "Source fixture changed during execution");
      const evidence = path.join(PROJECT_ROOT, "tmp/compatibility", runtime.selected.version);
      fs.mkdirSync(evidence, { recursive: true });
      fs.writeFileSync(path.join(evidence, "report.json"), JSON.stringify(report, null, 2));
      for (const [source, destination] of [["v0-expression.tsv", "expression_gene_log.tsv"],
        [out + "/_engineering/gene_missingness.tsv", "gene_missingness.tsv"],
        ["results/GSE10288/deg/topTable.tsv", "topTable.tsv"]]) fs.copyFileSync(path.join(fixture.project, source), path.join(evidence, destination));
      contracts.assertTolerance(comparison);
    }
    console.log(`Smoke PASS. Report: ${path.join(fixture.project, "smoke-report.json")}`);
    return report;
  } finally {
    await new Promise((resolve) => server.close(resolve));
    if (compatibilityMode) assert.equal(contracts.integrity(), fixtureHash);
  }
}

if (require.main === module) {
  const action = process.argv[2] === "--repair-only" ? repairSmoke(process.argv[3]) : runSmoke({ compatibilityMode: process.argv.includes("--compatibility") });
  action.catch((error) => { console.error(error); process.exitCode = 1; });
}
module.exports = { runSmoke };
