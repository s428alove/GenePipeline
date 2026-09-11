const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const VERSION_EXPRESSION = 'cat("GENEPIPELINE_R_VERSION=", as.character(getRversion()), "\\n", sep="")';

function probeRscript(executablePath, { run = spawnSync, timeout = 5000 } = {}) {
  try {
    const result = run(executablePath, ["--vanilla", "-e", VERSION_EXPRESSION], {
      encoding: "utf8", windowsHide: true, shell: false,
      timeout, maxBuffer: 64 * 1024
    });
    if (result.error || result.status !== 0) {
      return {
        version: null, executableStatus: "unusable",
        error: {
          code: result.error?.code || "R_PROBE_FAILED",
          message: result.error?.message || String(result.stderr || `Rscript exited with status ${result.status}`),
          exitCode: result.status, signal: result.signal || null
        }
      };
    }
    const match = String(result.stdout).match(/^GENEPIPELINE_R_VERSION=(\d+\.\d+\.\d+)\s*$/m);
    if (!match) {
      return { version: null, executableStatus: "unusable",
        error: { code: "INVALID_R_VERSION", message: "Rscript did not return a recognizable R version." } };
    }
    return { version: match[1], executableStatus: "usable", error: null };
  } catch (error) {
    return { version: null, executableStatus: "unusable",
      error: { code: error.code || "R_PROBE_FAILED", message: error.message } };
  }
}

function defaultInstallationRoots(env) {
  return [...new Set([
    path.join(env.ProgramW6432 || env.ProgramFiles || "C:\\Program Files", "R"),
    path.join(env.ProgramFiles || "C:\\Program Files", "R"),
    path.join(env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", "R"),
    ...(env.LOCALAPPDATA ? [path.join(env.LOCALAPPDATA, "Programs", "R")] : [])
  ])];
}

// Discovery only records facts. It deliberately knows nothing about compatibility.
function discoverR({
  env = process.env, platform = process.platform,
  pathValue = Object.entries(env).find(([key]) => key.toLowerCase() === "path")?.[1] || "",
  installationRoots = platform === "win32" ? defaultInstallationRoots(env) : [],
  probe = probeRscript
} = {}) {
  const candidates = [];
  const scanErrors = [];
  const seen = new Map();
  function add(executablePath, source) {
    const absolute = path.resolve(executablePath);
    try {
      if (!fs.statSync(absolute).isFile()) return;
      const real = fs.realpathSync(absolute);
      const key = platform === "win32" ? real.toLowerCase() : real;
      if (seen.has(key)) {
        const sources = seen.get(key).sources;
        if (!sources.includes(source)) sources.push(source);
        return;
      }
      const candidate = { detected: true, executablePath: real, source, sources: [source], ...probe(real) };
      seen.set(key, candidate);
      candidates.push(candidate);
    } catch (error) {
      if (error.code !== "ENOENT" && error.code !== "ENOTDIR") {
        scanErrors.push({ path: absolute, code: error.code, message: error.message });
      }
    }
  }

  const executable = platform === "win32" ? "Rscript.exe" : "Rscript";
  for (const entry of pathValue.split(platform === "win32" ? ";" : ":")) {
    const directory = entry.trim().replace(/^"(.*)"$/, "$1");
    // Ignore empty/relative entries: do not implicitly execute files in the working directory.
    if (directory && path.isAbsolute(directory)) add(path.join(directory, executable), "PATH");
  }
  for (const root of installationRoots) {
    try {
      const directories = fs.readdirSync(root, { withFileTypes: true })
        .filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort();
      for (const directory of directories) {
        for (const bin of ["bin", "bin/x64", "bin/i386"]) {
          add(path.join(root, directory, bin, executable), "installation-directory");
        }
      }
    } catch (error) {
      if (error.code !== "ENOENT") scanErrors.push({ path: root, code: error.code, message: error.message });
    }
  }
  return { detected: candidates.length > 0, candidates, scanErrors };
}

module.exports = { discoverR, probeRscript };
