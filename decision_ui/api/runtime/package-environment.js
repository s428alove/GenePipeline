const fs = require("node:fs");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { preflightR } = require("./r-preflight");

const PROJECT_ROOT = path.resolve(__dirname, "../../..");
const failure = (code, message, details = null) => ({
  ok: false, state: "not_ready", error: { code, message, details }
});

// All analysis subprocesses use the repository profile, never a user's R profile.
function analysisEnvironment(project = PROJECT_ROOT) {
  return { ...process.env, R_PROFILE_USER: path.join(project, ".Rprofile") };
}

function runEnvironment(mode, runtime, { project = PROJECT_ROOT, rebuild = false, onEvent = () => {}, log = () => {} } = {}) {
  return new Promise((resolve) => {
    const child = spawn(runtime.selected.executablePath,
      ["--vanilla", path.join(project, "tools/r-environment.R"), mode, project, rebuild ? "rebuild" : "normal"],
      { cwd: project, windowsHide: true, shell: false, stdio: ["ignore", "pipe", "pipe"] });
    let buffer = "";
    let tail = "";
    let result = null;
    let timedOut = false;
    const timeout = setTimeout(() => { timedOut = true; child.kill(); }, mode === "setup" ? 30 * 60 * 1000 : 90 * 1000);
    function record(chunk) {
      const text = String(chunk);
      tail = (tail + text).slice(-16000);
      log(text);
    }
    function line(value) {
      try {
        if (value.startsWith("GENEPIPELINE_ENV_EVENT=")) onEvent(JSON.parse(value.slice(23)));
        if (value.startsWith("GENEPIPELINE_ENV_RESULT=")) result = JSON.parse(value.slice(24));
      } catch { /* A malformed protocol line will produce a structured failure. */ }
    }
    child.stdout.on("data", (chunk) => {
      record(chunk);
      buffer += chunk;
      const lines = buffer.split(/\r?\n/);
      buffer = lines.pop();
      lines.forEach(line);
      if (buffer.length > 1024 * 1024) buffer = "";
    });
    child.stderr.on("data", record);
    child.once("error", (error) => {
      clearTimeout(timeout);
      resolve(failure(mode === "setup" ? "RENV_RESTORE_FAILED" : "PACKAGE_ENV_NOT_READY", error.message));
    });
    child.once("close", (code) => {
      clearTimeout(timeout);
      if (buffer) line(buffer);
      if (result && (code === 0 || !result.ok)) return resolve(result);
      resolve(failure(mode === "setup" ? "RENV_RESTORE_FAILED" : "PACKAGE_VALIDATION_FAILED",
        timedOut ? "Package environment operation timed out." : "Package environment operation failed.",
        { exitCode: code, output: tail }));
    });
  });
}

function createPackageEnvironment({ project = PROJECT_ROOT, run = runEnvironment, onState = () => {} } = {}) {
  let current = failure("PACKAGE_ENV_NOT_READY", "Package environment has not been checked.");
  let inFlight = null;
  let setupFailure = null;
  let compatibility = null;
  const lockPath = path.join(project, "renv", ".setup.lock");
  function update(value) {
    value = { ...value, compatibility };
    if (compatibility?.bestEffort) {
      value.warning = compatibility.warning;
      if (value.error) value.error = { ...value.error, guidance: compatibility.guidance,
        message: value.error.message + " " + compatibility.guidance };
    }
    current = value; onState(value); return value;
  }
  function busy() {
    return update({ ...failure("PACKAGE_ENV_NOT_READY", "GenePipeline is preparing its R packages. Wait for setup to finish, then retry."),
      state: inFlight ? current.state : "setting_up" });
  }
  function locked() { return fs.existsSync(lockPath); }
  async function inspect(runtime) {
    compatibility = runtime.compatibility || null;
    if (!runtime.ok) return runtime;
    if (inFlight || locked()) return busy();
    const result = await run("check", runtime, { project });
    // A setup may have started while this read-only probe was running.
    if (inFlight || locked()) return busy();
    if (result.ok) setupFailure = null;
    return update(!result.ok && setupFailure ? { ...result, error: setupFailure.error, lastSetup: setupFailure } : result);
  }
  function setup(runtime) {
    if (inFlight) return inFlight;
    compatibility = runtime.compatibility || null;
    if (!runtime.ok) return Promise.resolve(update(runtime));
    setupFailure = null;
    update({ ok: false, state: "checking", error: null });
    inFlight = (async () => {
      let lock;
      let logFile;
      try {
        fs.mkdirSync(path.dirname(lockPath), { recursive: true });
        // Reclaim only locks whose recorded owning process no longer exists.
        if (locked()) {
          const owner = JSON.parse(fs.readFileSync(lockPath, "utf8"));
          try { process.kill(owner.pid, 0); }
          catch (error) { if (error.code === "ESRCH") fs.unlinkSync(lockPath); else throw error; }
        }
        try { lock = fs.openSync(lockPath, "wx"); }
        catch (error) {
          if (error.code === "EEXIST") return update(failure("PACKAGE_ENV_NOT_READY", "Another environment setup is running. Retry after it finishes."));
          throw error;
        }
        fs.writeFileSync(lock, JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() }));
        const before = await run("check", runtime, { project });
        if (before.ok) return update(before); // Ready startup never restores.
        const logDir = path.join(project, "logs/environment");
        fs.mkdirSync(logDir, { recursive: true });
        logFile = path.join(logDir, `setup-${Date.now()}-${process.pid}.log`);
        const restored = await run("setup", runtime, {
          project,
          // Version-correct but unloadable packages need a rebuild, not a no-op
          // restore. Validation happens in a separate process, avoiding DLL locks.
          rebuild: before.error?.code === "PACKAGE_VALIDATION_FAILED" && !before.mismatches?.length,
          log: (text) => fs.appendFileSync(logFile, text),
          onEvent: (event) => update({ ok: false, ...event, logFile, error: null })
        });
        if (!restored.ok) { setupFailure = { ...restored, logFile }; return update(setupFailure); }
        update({ ok: false, state: "validating", logFile, error: null });
        const after = await run("check", runtime, { project });
        return update({ ...after, logFile });
      } catch (error) {
        return update(failure("PACKAGE_ENV_NOT_READY", error.message, { logFile }));
      } finally {
        if (lock !== undefined) { fs.closeSync(lock); fs.unlinkSync(lockPath); }
      }
    })().finally(() => { inFlight = null; });
    return inFlight;
  }
  return { inspect, setup, status: () => current, isBusy: () => Boolean(inFlight) || locked() };
}

if (require.main === module) {
  const environment = createPackageEnvironment({ onState: (s) => console.log(`[environment] ${s.state}: ${s.message || s.error?.message || ""}`) });
  const runtime = preflightR();
  const operation = process.argv[2] === "setup" ? environment.setup(runtime) : environment.inspect(runtime);
  operation.then((result) => {
    console.log(JSON.stringify(result, null, 2));
    process.exitCode = result.ok ? 0 : 1;
  });
}

module.exports = { createPackageEnvironment, runEnvironment, analysisEnvironment, PROJECT_ROOT };
