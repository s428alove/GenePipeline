const { test } = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const { spawn, spawnSync } = require("node:child_process");
const { once } = require("node:events");
const { createApp } = require("../decision_ui/api/server");
const { preflightR } = require("../decision_ui/api/runtime/r-preflight");
const { discoverR } = require("../decision_ui/api/runtime/r-discovery");

async function serve(t, options) {
  const server = createApp(options).listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}`;
}

test("missing R returns HTTP 503 before any R-backed route touches data; UI stays available", async (t) => {
  const base = await serve(t, {
    preflight: () => preflightR({ discover: () => discoverR({ pathValue: "", installationRoots: [] }) })
  });
  for (const route of ["/api/preflight/r", "/api/v0/run", "/api/v1/run", "/api/project/load",
    "/api/decision/export-and-merge", "/api/decision/run-validation"]) {
    const response = await fetch(base + route, route === "/api/preflight/r" ? {} : {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ gse: "GSE10288" })
    });
    const body = await response.json();
    assert.equal(response.status, 503, route);
    assert.equal(body.stage, "r_preflight");
    assert.equal(body.error.code, "R_NOT_AVAILABLE");
    assert.equal(body.error.details.discovery.detected, false);
    assert.match(body.message, /install R/i);
  }
  assert.deepEqual(await (await fetch(base + "/api/health")).json(), { status: "ok" });
  assert.equal((await fetch(base)).status, 200);
});

test("actual R preflight and unchanged route validation", async (t) => {
  const base = await serve(t);
  const response = await fetch(base + "/api/preflight/r");
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  assert.equal(body.data.selected.executableStatus, "usable");
  const invalid = await fetch(base + "/api/v1/run", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ gse: "invalid" })
  });
  assert.equal(invalid.status, 400);
  assert.equal((await invalid.json()).error.code, "INVALID_GSE");
});

test("server executes discovered R against isolated sample metadata", async (t) => {
  const runtime = preflightR();
  assert.equal(runtime.ok, true);
  const packages = spawnSync(runtime.selected.executablePath, ["-e",
    'cat(all(vapply(c("optparse", "readr", "dplyr", "stringr"), requireNamespace, logical(1), quietly=TRUE)))'
  ], { encoding: "utf8", windowsHide: true, timeout: 10000 });
  if (packages.status === 0 && packages.stdout.trim() === "FALSE") {
    t.skip("Local R is missing Decision runner packages; install README prerequisites to enable this integration test.");
    return;
  }
  assert.equal(packages.status, 0, packages.stderr);
  const root = path.resolve(__dirname, "..");
  const directory = fs.mkdtempSync(path.join(__dirname, "runtime fixture "));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  fs.writeFileSync(path.join(directory, "sample_metadata_raw.tsv"),
    "sample_id\ttitle\tsource_name_ch1\nGSM1\tcontrol\tnormal\nGSM2\tcase\ttumor\n");
  const base = await serve(t);
  const response = await fetch(base + "/api/project/load", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ gse: "GSE999999999", out: path.relative(root, directory) })
  });
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  assert.equal(body.n_samples, 2);
  assert.equal(fs.existsSync(path.join(directory, "sample_metadata_decision_candidates.tsv")), true);
});

test("real server entry starts from a different cwd and serves the current frontend", async (t) => {
  const entry = path.resolve(__dirname, "../decision_ui/api/server.js");
  const child = spawn(process.execPath, [entry], { cwd: __dirname, windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
  const exited = once(child, "exit");
  t.after(async () => { if (child.exitCode === null) child.kill(); await exited; });
  let output = "";
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Server startup timed out: " + output)), 10000);
    child.stdout.on("data", (chunk) => {
      output += chunk;
      if (output.includes("running at")) { clearTimeout(timeout); resolve(); }
    });
    child.stderr.on("data", (chunk) => { output += chunk; });
    child.once("error", (error) => { clearTimeout(timeout); reject(error); });
    child.once("exit", () => { clearTimeout(timeout); reject(new Error(output)); });
  });
  for (const asset of ["index.html", "app.js", "styles.css"]) {
    const response = await fetch(`http://127.0.0.1:3001/${asset}`);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), fs.readFileSync(path.resolve(__dirname, "../decision_ui/frontend", asset), "utf8"));
  }
  assert.deepEqual(await (await fetch("http://127.0.0.1:3001/api/health")).json(), { status: "ok" });
});
