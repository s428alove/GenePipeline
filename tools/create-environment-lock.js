// Maintainer-only: resolve dependencies, then snapshot an actual fresh restore.
// Normal startup never invokes this file or changes renv.lock.
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { preflightR } = require("../decision_ui/api/runtime/r-preflight");
const { createPackageEnvironment, PROJECT_ROOT } = require("../decision_ui/api/runtime/package-environment");
const { environmentFixture } = require("../tests/environment-fixture");

async function main() {
  const runtime = preflightR();
  if (!runtime.ok) throw new Error(runtime.error.message);
  function r(args, cwd = PROJECT_ROOT) {
    const result = spawnSync(runtime.selected.executablePath, ["--vanilla", ...args], { cwd, stdio: "inherit", windowsHide: true });
    if (result.status !== 0) throw new Error("Maintainer lock operation failed");
  }
  if (process.argv[2] !== "--normalize") r(["tools/create-environment-lock.R"]);
  const original = JSON.parse(fs.readFileSync(path.join(PROJECT_ROOT, "renv.lock")));
  const fixture = environmentFixture({ cache: true, prefix: "lock-roundtrip-" });
  try {
    const restored = await createPackageEnvironment({ project: fixture.project,
      onState: (s) => console.log(`[lock roundtrip] ${s.state}: ${s.error?.message || ""}`)
    }).setup(runtime);
    if (!restored.packages?.every((p) => p.usable) || restored.mismatches?.length) {
      throw new Error(JSON.stringify(restored));
    }
    r(["-e", 'source("tools/r-environment-lib.R"); gp_activate(getwd()); renv::snapshot(project=getwd(),type="explicit",prompt=FALSE)'], fixture.project);
    const normalized = JSON.parse(fs.readFileSync(path.join(fixture.project, "renv.lock")));
    for (const [name, record] of Object.entries(original.Packages)) {
      if (normalized.Packages[name]?.Version !== record.Version) throw new Error(`Roundtrip changed ${name}'s version`);
    }
    fs.copyFileSync(path.join(fixture.project, "renv.lock"), path.join(PROJECT_ROOT, "renv.lock"));
    const ready = await createPackageEnvironment({ onState: (s) => console.log(`[root environment] ${s.state}`) }).setup(runtime);
    if (!ready.ok) throw new Error(JSON.stringify(ready));
    console.log("Lockfile created from a real restore; root environment synchronized.");
  } finally { fixture.dispose(); }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
