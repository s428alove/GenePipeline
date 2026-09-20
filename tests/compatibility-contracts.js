const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const assert = require("node:assert/strict");
const { parse } = require("csv-parse/sync");
const FIXTURE = path.join(__dirname, "fixtures/GSE10288");
const sha256 = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const json = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
function integrity(root = FIXTURE) {
  const manifest = json(path.join(root, "checksums.json"));
  function inventory(dir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
      const file = path.join(dir, entry.name);
      return entry.isDirectory() ? inventory(file) : [path.relative(root, file).split(path.sep).join("/")];
    });
  }
  assert.deepEqual(inventory(root).filter((p) => !["checksums.json", "README.md"].includes(p)).sort(), Object.keys(manifest).sort(), "Fixture file inventory changed");
  for (const [file, expected] of Object.entries(manifest)) {
    const resolved = path.resolve(root, file);
    assert.ok(resolved.startsWith(path.resolve(root) + path.sep), "Invalid fixture checksum path");
    assert.equal(sha256(resolved), expected, `Fixture integrity: ${file}`);
  }
  return sha256(path.join(root, "checksums.json"));
}
function table(file, key) {
  const rows = parse(fs.readFileSync(file, "utf8"), { delimiter: "\t", skip_empty_lines: true, relax_quotes: true });
  const columns = rows.shift();
  assert.ok(columns?.includes(key), `Missing ${key}: ${file}`);
  assert.equal(new Set(columns).size, columns.length, `Duplicate columns: ${file}`);
  const map = new Map();
  for (const cells of rows) {
    assert.equal(cells.length, columns.length, `Ragged row: ${file}`);
    const row = Object.fromEntries(columns.map((c, i) => [c, cells[i]]));
    assert.ok(row[key] && row[key] !== "NA", `Empty key: ${file}`);
    assert.ok(!map.has(row[key]), `Duplicate ${key}: ${row[key]}`);
    map.set(row[key], row);
  }
  return { columns, map };
}
function number(value) {
  assert.match(String(value), /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/, `Not numeric: ${value}`);
  const n = Number(value);
  assert.ok(Number.isFinite(n), `Not finite: ${value}`);
  return n;
}
function compareTable(actualFile, expectedFile, key, numeric, exact, tolerance) {
  const actual = table(actualFile, key), expected = table(expectedFile, key);
  assert.deepEqual([...actual.columns].sort(), [...expected.columns].sort(), "Column set changed");
  assert.deepEqual([...actual.map.keys()].sort(), [...expected.map.keys()].sort(), `${key} set changed`);
  const metrics = Object.fromEntries(numeric.map((c) => [c, { maxAbsolute: 0, maxRelative: 0, count: 0, outsideTolerance: 0 }]));
  for (const [id, a] of actual.map) {
    const b = expected.map.get(id);
    for (const c of exact) assert.equal(a[c], b[c], `${id}.${c}`);
    for (const c of numeric) {
      const x = number(a[c]), y = number(b[c]);
      const absolute = Math.abs(x - y), scale = Math.max(Math.abs(x), Math.abs(y));
      const relative = scale === 0 ? 0 : absolute / scale;
      const m = metrics[c];
      m.count++; m.maxAbsolute = Math.max(m.maxAbsolute, absolute); m.maxRelative = Math.max(m.maxRelative, relative);
      if (absolute > tolerance.absolute + tolerance.relative * scale) m.outsideTolerance++;
    }
  }
  return metrics;
}
function summary(file) {
  return Object.fromEntries(fs.readFileSync(file, "utf8").trim().split(/\r?\n/).map((line) => {
    const i = line.indexOf(": "); return [line.slice(0, i), line.slice(i + 2)];
  }));
}
function significant(file, config) {
  return [...table(file, "ID").map.values()].filter((r) => number(r["adj.P.Val"]) <= config.padj_cutoff &&
    Math.abs(number(r.logFC)) >= config.lfc_cutoff).map((r) => r.ID).sort();
}
function validateV0(project, root = FIXTURE) {
  const expected = path.join(root, "expected"), output = path.join(project, "data_processed/GSE10288");
  const baseline = json(path.join(expected, "contracts.json"));
  const config = json(path.join(root, "config/parameters.json"));
  const tolerance = json(path.join(root, "config/tolerance.json"));
  const gate = json(path.join(output, "_engineering/missingness_gate.json"));
  assert.equal(gate.status, "passed"); assert.equal(gate.canonical_expression_ready, true);
  assert.equal(gate.review_required, false);
  for (const [key, value] of Object.entries({ genes_before: baseline.genesBefore, genes_removed: baseline.genesRemoved,
    genes_after: baseline.genesAfter, samples: baseline.samples, configured_threshold: config.v0.max_missing_gene_fraction })) assert.equal(gate[key], value, key);
  const s = summary(path.join(output, "_engineering/V0_summary.txt"));
  for (const [key, value] of Object.entries({ RawProbes: baseline.rawProbes, MappedProbes: baseline.mappedProbes,
    GenesOutput: baseline.genesAfter, Samples: baseline.samples, AggMethod: config.v0.agg, ForceLog2: config.v0.force_log2,
    Log2Applied: "TRUE" })) assert.equal(s[key], String(value), key);
  const missingness = compareTable(path.join(output, "_engineering/gene_missingness.tsv"), path.join(expected, "gene_missingness.tsv"),
    "gene_id", ["missing_fraction"], ["n_missing_samples", "action", "reason"], tolerance);
  const expr = path.join(output, "expression_gene_log.tsv");
  const t = table(expr, "gene_id"), reference = table(path.join(expected, "expression_gene_log.tsv"), "gene_id");
  assert.equal(t.map.size, baseline.genesAfter); assert.equal(t.columns.length - 1, baseline.samples);
  assert.deepEqual(t.columns, reference.columns, "Sample order changed");
  const matrix = compareTable(expr, path.join(expected, "expression_gene_log.tsv"), "gene_id", t.columns.filter((c) => c !== "gene_id"), [], tolerance);
  return { gate, mappedFeatures: Number(s.MappedProbes), missingness, matrix };
}
function validateV1(project, root = FIXTURE) {
  const expected = path.join(root, "expected");
  const config = json(path.join(root, "config/parameters.json"));
  const tolerance = json(path.join(root, "config/tolerance.json"));
  const deg = path.join(project, "results/GSE10288/deg/topTable.tsv");
  const metrics = compareTable(deg, path.join(expected, "topTable.tsv"), "ID",
    ["logFC", "P.Value", "adj.P.Val", "t", "B"], ["Gene.symbol", "Gene.title"], tolerance);
  const ids = significant(deg, config.v1);
  assert.deepEqual(ids, json(path.join(expected, "contracts.json")).significantIDs, "Significant gene identity changed");
  assert.deepEqual([...table(deg, "ID").map.keys()].sort(), [...table(path.join(expected, "expression_gene_log.tsv"), "gene_id").map.keys()].sort());
  return { metrics, significantIDs: ids, rowCount: table(deg, "ID").map.size };
}
function validateDecision(project, root = FIXTURE) {
  const fixed = table(path.join(root, "decision/sample_metadata_decision.tsv"), "sample_id");
  const merged = table(path.join(project, "data_processed/GSE10288/sample_metadata_merged.tsv"), "sample_id");
  assert.deepEqual([...merged.map.keys()].sort(), [...fixed.map.keys()].sort(), "Decision cohort IDs changed");
  for (const [id, row] of fixed.map) for (const col of ["include", "group_label", "case_control"])
    assert.equal(merged.map.get(id)[col], row[col], `Decision ${id}.${col}`);
  const cohort = json(path.join(root, "config/parameters.json")).cohort;
  const included = [...merged.map.values()].filter((r) => r.include === "TRUE");
  assert.equal(included.filter((r) => r.group_label === cohort.case && r.case_control === "case").length, cohort.caseCount);
  assert.equal(included.filter((r) => r.group_label === cohort.control && r.case_control === "control").length, cohort.controlCount);
  return { samples: merged.map.size, included: included.length, caseCount: cohort.caseCount, controlCount: cohort.controlCount };
}
function assertTolerance(report) {
  const metrics = [...Object.values(report.v0.matrix), ...Object.values(report.v0.missingness),
    ...Object.values(report.v1.metrics), ...Object.values(report.thresholdsOnly.metrics)];
  assert.equal(metrics.reduce((n, m) => n + m.outsideTolerance, 0), 0,
    "Numeric divergence: inspect compatibility report; do not automatically rewrite the reference or widen tolerance.");
}
module.exports = { FIXTURE, sha256, json, integrity, table, number, compareTable, validateV0, validateV1, validateDecision, assertTolerance };
