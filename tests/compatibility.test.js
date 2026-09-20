const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { once } = require("node:events");
const { compatibility, registry } = require("../decision_ui/api/runtime/r-compatibility");
const { selectR } = require("../decision_ui/api/runtime/r-selection");
const { preflightR } = require("../decision_ui/api/runtime/r-preflight");
const { createApp } = require("../decision_ui/api/server");
const { createPackageEnvironment } = require("../decision_ui/api/runtime/package-environment");
const c = require("./compatibility-contracts");

test("compatibility states do not equate detection or package readiness with validation", () => {
  const policy = { ...registry, validated: { "4.5.2": "evidence", "4.5.3": "evidence" }, incompatible: { "4.6.1": "Known test failure" } };
  for (const v of ["4.5.2", "4.5.3"]) assert.equal(compatibility(v, policy).status, "validated");
  for (const v of ["4.5.0", "4.5.4", "4.6.0", "5.0.0"]) {
    const result = compatibility(v, policy);
    assert.equal(result.status, "unvalidated"); assert.equal(result.supported, false);
    assert.equal(result.bestEffort, true); assert.match(result.warning, /do not need to remove/);
  }
  assert.equal(compatibility("4.4.9", policy).allowed, false);
  assert.equal(compatibility("4.6.1", policy).status, "incompatible");
  assert.equal(compatibility("4.6.1", policy).allowed, false);
  assert.equal(compatibility("invalid", policy).status, "unsupported");
  assert.equal(compatibility("4.5.2", policy, "linux").status, "unsupported");
});

test("unsupported/incompatible stop before packages; newer R carries warning and failure guidance", async (t) => {
  for (const [version, incompatible, code] of [["4.4.3", {}, "R_UNSUPPORTED"], ["4.6.1", { "4.6.1": "Known issue" }, "R_INCOMPATIBLE"], ["4.6.0", {}, null]]) {
    let checks = 0;
    const runtime = preflightR({ discover: () => ({ detected: true, candidates: [{ version, executableStatus: "usable", sources: ["PATH"] }] }),
      select: (d) => selectR(d, { ...registry, incompatible }) });
    const app = createApp({ preflight: () => runtime, environment: {
      inspect: async () => { checks++; return { ok: false, error: { code: "RENV_RESTORE_FAILED", message: "test restore failure" } }; }
    } });
    const server = app.listen(0, "127.0.0.1"); await once(server, "listening");
    t.after(() => new Promise((resolve) => server.close(resolve)));
    const result = await fetch(`http://127.0.0.1:${server.address().port}/api/v0/run`, { method: "POST", headers: { "Content-Type": "application/json" }, body: '{"gse":"GSE10288"}' });
    const body = await result.json(); assert.equal(result.status, 503);
    if (code) { assert.equal(body.stage, "r_compatibility"); assert.equal(body.error.code, code); assert.equal(checks, 0); }
    else { assert.equal(checks, 1); assert.equal(body.compatibility.status, "unvalidated"); assert.match(body.message, /alongside/); assert.equal(body.warnings.length, 1); }
  }
});

test("Best-effort package Ready retains unvalidated status", async () => {
  const comp = compatibility("4.6.0");
  const manager = createPackageEnvironment({ project: path.join(os.tmpdir(), "nonexistent-compatibility-probe"), run: async () => ({ ok: true, state: "ready" }) });
  const result = await manager.inspect({ ok: true, compatibility: comp });
  assert.equal(result.ok, true); assert.equal(result.compatibility.status, "unvalidated"); assert.match(result.warning, /unvalidated/);
});

test("frozen fixture integrity, schema and significant gene identity are internally consistent", () => {
  c.integrity();
  const expected = path.join(c.FIXTURE, "expected");
  const expression = c.table(path.join(expected, "expression_gene_log.tsv"), "gene_id");
  const deg = c.table(path.join(expected, "topTable.tsv"), "ID");
  assert.equal(expression.map.size, 254); assert.equal(expression.columns.length - 1, 46);
  assert.deepEqual([...expression.map.keys()].sort(), [...deg.map.keys()].sort());
  const missing = c.table(path.join(expected, "gene_missingness.tsv"), "gene_id");
  assert.equal(missing.map.size, 31);
  for (const id of missing.map.keys()) assert.equal(expression.map.has(id), false);
  const config = c.json(path.join(c.FIXTURE, "config/parameters.json"));
  const sig = [...deg.map.values()].filter((x) => +x["adj.P.Val"] <= config.v1.padj_cutoff && Math.abs(+x.logFC) >= config.v1.lfc_cutoff).map((x) => x.ID).sort();
  assert.deepEqual(sig, c.json(path.join(expected, "contracts.json")).significantIDs);
  assert.equal(sig.length, 27);
});

test("numeric comparison aligns keys, measures drift and rejects duplicate/invalid cells", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gp-contract-")); t.after(() => fs.rmSync(dir, { recursive: true }));
  const a = path.join(dir, "actual.tsv"), b = path.join(dir, "reference.tsv");
  fs.writeFileSync(b, "ID\tx\nA\t1\nB\t0\n"); fs.writeFileSync(a, "ID\tx\nB\t0\nA\t1\n");
  const compare = () => c.compareTable(a, b, "ID", ["x"], [], { absolute: 0, relative: 0 });
  assert.equal(compare().x.outsideTolerance, 0);
  fs.writeFileSync(a, "ID\tx\nA\t1.25\nB\t0\n");
  assert.deepEqual(compare().x, { maxAbsolute: 0.25, maxRelative: 0.2, count: 2, outsideTolerance: 1 });
  for (const content of ["ID\tx\nA\t1\nA\t1\n", "ID\tx\nA\tNaN\nB\t0\n", "ID\tx\nA\t\nB\t0\n", "ID\tx\tx\nA\t1\t1\n"]) {
    fs.writeFileSync(a, content); assert.throws(compare);
  }
  const fixture = path.join(dir, "fixture"); fs.mkdirSync(fixture);
  fs.writeFileSync(path.join(fixture, "checksums.json"), JSON.stringify({ "data.txt": "bad-hash" }));
  fs.writeFileSync(path.join(fixture, "data.txt"), "changed"); assert.throws(() => c.integrity(fixture), /Fixture integrity/);
});
