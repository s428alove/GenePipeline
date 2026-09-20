// Read actual outputs from both required targets; never update a baseline/policy.
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const c = require("../tests/compatibility-contracts");
const root = path.resolve(__dirname, "..");
const dir = path.join(root, "tmp/compatibility");
const versions = require("../decision_ui/api/runtime/r-compatibility.json").validationTargets;
const tolerance = c.json(path.join(c.FIXTURE, "config/tolerance.json"));
function aggregate(metrics) {
  const all = Object.values(metrics);
  return { maxAbsolute: Math.max(...all.map((x) => x.maxAbsolute)), maxRelative: Math.max(...all.map((x) => x.maxRelative)),
    count: all.reduce((n, x) => n + x.count, 0), outsideTolerance: all.reduce((n, x) => n + x.outsideTolerance, 0) };
}
const targets = versions.map((version) => {
  const suite = c.json(path.join(dir, version, "suite.json"));
  const report = c.json(path.join(dir, version, "report.json"));
  assert.equal(suite.ok, true); assert.equal(suite.version, version);
  assert.equal(report.runtime.selected.version, version); assert.equal(report.environment.rVersion, version);
  assert.equal(suite.fixtureHash, c.integrity()); assert.equal(suite.lockHash, c.sha256(path.join(root, "renv.lock")));
  assert.equal(suite.bootstrap, true); assert.equal(suite.restore, true);
  c.assertTolerance(report.comparison);
  return { ...suite, baselineDrift: { matrix: aggregate(report.comparison.v0.matrix),
    missingness: report.comparison.v0.missingness, deg: report.comparison.v1.metrics },
    outputHashes: Object.fromEntries(["expression_gene_log.tsv", "gene_missingness.tsv", "topTable.tsv"].map((f) => [f, c.sha256(path.join(dir, version, f))])) };
});
assert.equal(versions.length, 2, "Update pairwise measurement when adding targets");
const [a, b] = versions.map((v) => path.join(dir, v));
const matrixCols = c.table(path.join(a, "expression_gene_log.tsv"), "gene_id").columns.filter((x) => x !== "gene_id");
const crossPatch = {
  matrix: aggregate(c.compareTable(path.join(a, "expression_gene_log.tsv"), path.join(b, "expression_gene_log.tsv"), "gene_id", matrixCols, [], tolerance)),
  missingness: c.compareTable(path.join(a, "gene_missingness.tsv"), path.join(b, "gene_missingness.tsv"), "gene_id", ["missing_fraction"], ["n_missing_samples", "action", "reason"], tolerance),
  deg: c.compareTable(path.join(a, "topTable.tsv"), path.join(b, "topTable.tsv"), "ID", ["logFC", "P.Value", "adj.P.Val", "t", "B"], ["Gene.symbol", "Gene.title"], tolerance)
};
const report = { targets, crossPatch, tolerance };
fs.writeFileSync(path.join(dir, "drift.json"), JSON.stringify(report, null, 2) + "\n");
console.log(JSON.stringify(crossPatch, null, 2));
assert.equal([crossPatch.matrix, ...Object.values(crossPatch.missingness), ...Object.values(crossPatch.deg)].reduce((n, x) => n + x.outsideTolerance, 0), 0,
  "Cross-patch divergence: maintainer review required; no automatic baseline/tolerance update.");
