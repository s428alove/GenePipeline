const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { once } = require("node:events");
const { createPackageEnvironment, runEnvironment, PROJECT_ROOT } = require("../decision_ui/api/runtime/package-environment");
const { preflightR } = require("../decision_ui/api/runtime/r-preflight");
const { createApp } = require("../decision_ui/api/server");
const { environmentFixture } = require("./environment-fixture");
const runtime = preflightR();
const notReady = { ok: false, state: "not_ready", error: { code: "PACKAGE_ENV_NOT_READY", message: "Missing package" } };

test("A: real repository environment is active, synchronized and all central imports load", async () => {
  assert.equal(runtime.ok, true);
  const result = await runEnvironment("check", runtime);
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.equal(result.active, true);
  assert.equal(result.synchronized, true);
  const manifest = fs.readFileSync(path.join(PROJECT_ROOT, "DESCRIPTION"), "utf8");
  const imports = manifest.match(/Imports:\s*([\s\S]*?)\nSuggests:/)[1].split(",").map((s) => s.trim());
  assert.equal(imports.length, 11);
  assert.deepEqual(result.packages.map((p) => p.package), imports);
  assert.equal(result.packages.every((p) => p.usable), true);
});

test("Ready startup checks once and never restores; no-R never reaches packages", async (t) => {
  const fixture = environmentFixture(); t.after(fixture.dispose);
  const calls = [];
  const manager = createPackageEnvironment({ project: fixture.project, run: async (mode) => { calls.push(mode); return { ok: true, state: "ready" }; } });
  assert.equal((await manager.setup(runtime)).ok, true);
  assert.deepEqual(calls, ["check"]);
  assert.equal((await manager.setup({ ok: false, error: { code: "R_NOT_AVAILABLE" } })).error.code, "R_NOT_AVAILABLE");
  assert.deepEqual(calls, ["check"]);
});

test("B: missing project package blocks all R-backed endpoints without installing", async (t) => {
  const ready = await runEnvironment("check", runtime);
  const fixture = environmentFixture({ ready }); t.after(fixture.dispose);
  fs.unlinkSync(path.join(fixture.library, "optparse"));
  const result = await runEnvironment("check", runtime, { project: fixture.project });
  assert.equal(result.ok, false);
  assert.equal(result.packages.find((p) => p.package === "optparse").usable, false);
  assert.equal(result.synchronized, false);
  let setupCalls = 0;
  const environment = { inspect: async () => result, setup: () => { setupCalls++; }, isBusy: () => false };
  const server = createApp({ preflight: () => runtime, environment }).listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise((resolve) => server.close(resolve)));
  for (const route of ["v0/run", "v1/run", "project/load", "decision/export-and-merge", "decision/run-validation"]) {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/${route}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: "{}"
    });
    assert.equal(response.status, 503);
    assert.equal((await response.json()).stage, "package_environment");
  }
  assert.equal(setupCalls, 0);
  assert.equal(fs.existsSync(path.join(fixture.library, "optparse")), false);
});

test("C: missing renv selects setup/bootstrap; concurrent callers share one restore", async (t) => {
  const fixture = environmentFixture(); t.after(fixture.dispose);
  const calls = [];
  const states = [];
  let complete;
  const paused = new Promise((resolve) => { complete = resolve; });
  let checks = 0;
  const manager = createPackageEnvironment({ project: fixture.project, onState: (s) => states.push(s.state),
    run: async (mode, r, options) => {
      calls.push(mode);
      if (mode === "check") return checks++ ? { ok: true, state: "ready" } : notReady;
      options.onEvent({ state: "bootstrapping", message: "Installing pinned renv" });
      await paused;
      options.onEvent({ state: "restoring", message: "Restoring packages" });
      return { ok: true, state: "restored" };
    }
  });
  const first = manager.setup(runtime);
  const second = manager.setup(runtime);
  assert.equal(first, second);
  assert.equal((await manager.inspect(runtime)).ok, false);
  complete();
  assert.equal((await first).ok, true);
  assert.deepEqual(calls, ["check", "setup", "check"]);
  assert.ok(states.includes("bootstrapping"));
  assert.ok(states.includes("validating"));
});

test("D: real invalid lockfile restore fails explicitly and remains Not Ready", async (t) => {
  const fixture = environmentFixture(); t.after(fixture.dispose);
  fs.writeFileSync(path.join(fixture.project, "renv.lock"), "{invalid json");
  const manager = createPackageEnvironment({ project: fixture.project });
  const result = await manager.setup(runtime);
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "RENV_RESTORE_FAILED", JSON.stringify(result));
  assert.equal((await manager.inspect(runtime)).ok, false);
  assert.equal(manager.status().error.code, "RENV_RESTORE_FAILED");
  assert.equal(fs.existsSync(path.join(fixture.project, "renv/.setup.lock")), false);
});

test("missing renv check never installs; failed automatic bootstrap has its own error code", async (t) => {
  const fixture = environmentFixture({ bootstrap: false }); t.after(fixture.dispose);
  const file = path.join(fixture.project, "DESCRIPTION");
  fs.writeFileSync(file, fs.readFileSync(file, "utf8").replace(
    /Config\/GenePipeline\/CRAN: .*/, "Config/GenePipeline/CRAN: file:///genepipeline-missing-test-repository"));
  const before = await runEnvironment("check", runtime, { project: fixture.project });
  assert.equal(before.ok, false);
  assert.equal(fs.existsSync(path.join(fixture.project, "renv/bootstrap")), false);
  const manager = createPackageEnvironment({ project: fixture.project });
  const result = await manager.setup(runtime);
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "RENV_BOOTSTRAP_FAILED", JSON.stringify(result));
  assert.match(fs.readFileSync(result.logFile, "utf8"), /bootstrapping/);
});

test("version-correct but broken package is rejected and requests rebuild", async (t) => {
  const ready = await runEnvironment("check", runtime);
  const fixture = environmentFixture({ ready }); t.after(fixture.dispose);
  const target = path.join(fixture.library, "optparse");
  fs.unlinkSync(target);
  fs.mkdirSync(target);
  fs.copyFileSync(path.join(ready.library, "optparse/DESCRIPTION"), path.join(target, "DESCRIPTION"));
  const broken = await runEnvironment("check", runtime, { project: fixture.project });
  assert.equal(broken.ok, false);
  assert.equal(broken.error.code, "PACKAGE_VALIDATION_FAILED");
  assert.deepEqual(broken.mismatches, []);
  let rebuilding = false;
  const manager = createPackageEnvironment({ project: fixture.project, run: async (mode, r, options) => {
    if (mode === "check") return rebuilding ? { ok: true, state: "ready" } : broken;
    rebuilding = options.rebuild;
    return { ok: true, state: "restored" };
  } });
  assert.equal((await manager.setup(runtime)).ok, true);
  assert.equal(rebuilding, true);
});

test("real restore repairs a missing package in an isolated library from the local cache", async (t) => {
  const ready = await runEnvironment("check", runtime);
  const fixture = environmentFixture({ ready, cache: true }); t.after(fixture.dispose);
  fs.unlinkSync(path.join(fixture.library, "optparse"));
  const manager = createPackageEnvironment({ project: fixture.project });
  const repaired = await manager.setup(runtime);
  assert.equal(repaired.ok, true, JSON.stringify(repaired));
  assert.equal(repaired.synchronized, true);
  assert.equal(fs.existsSync(path.join(fixture.library, "optparse/DESCRIPTION")), true);
});
