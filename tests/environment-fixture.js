const fs = require("node:fs");
const path = require("node:path");
const { PROJECT_ROOT } = require("../decision_ui/api/runtime/package-environment");

function environmentFixture({ ready = null, prefix = "environment-", cache = false, bootstrap = true } = {}) {
  const parent = path.join(PROJECT_ROOT, "tmp/phase2-smoke");
  fs.mkdirSync(parent, { recursive: true });
  const project = fs.mkdtempSync(path.join(parent, prefix));
  for (const name of ["DESCRIPTION", "renv.lock", ".Rprofile", "tools/r-environment-lib.R", "tools/r-environment.R", "renv/settings.json"]) {
    const destination = path.join(project, name);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.join(PROJECT_ROOT, name), destination);
  }
  if (bootstrap) fs.cpSync(path.join(PROJECT_ROOT, "renv/bootstrap"), path.join(project, "renv/bootstrap"), { recursive: true });
  const links = [];
  const link = (source, target) => { fs.symlinkSync(source, target, "junction"); links.push(target); };
  let library;
  if (ready) {
    library = path.join(project, path.relative(PROJECT_ROOT, ready.library));
    fs.mkdirSync(library, { recursive: true });
    for (const name of fs.readdirSync(ready.library)) {
      if (fs.existsSync(path.join(ready.library, name, "DESCRIPTION"))) link(path.join(ready.library, name), path.join(library, name));
    }
  }
  if (cache) link(path.join(PROJECT_ROOT, "renv/cache"), path.join(project, "renv/cache"));
  function dispose() {
    // Remove junctions themselves before deleting this test-owned directory.
    for (const target of links) {
      try { if (fs.lstatSync(target).isSymbolicLink()) fs.unlinkSync(target); }
      catch (error) { if (error.code !== "ENOENT") throw error; }
    }
    if (!path.resolve(project).startsWith(path.resolve(parent) + path.sep)) throw new Error("Invalid fixture cleanup path");
    fs.rmSync(project, { recursive: true, force: true });
  }
  return { project, library, dispose };
}

module.exports = { environmentFixture };
