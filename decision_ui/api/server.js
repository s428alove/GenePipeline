const express = require("express");
const cors = require("cors");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

const { preflightR } = require("./runtime/r-preflight");
const { createPackageEnvironment, analysisEnvironment } = require("./runtime/package-environment");

function createApp({ preflight = preflightR, projectRoot = path.resolve(__dirname, "../.."),
  environment = createPackageEnvironment({ project: projectRoot }) } = {}) {
const app = express();
const PROJECT_ROOT = projectRoot;

app.use(cors());
app.use(express.json());

// Expose only generated analysis artifacts needed by the frontend.
app.use(
  "/figures",
  express.static(path.join(PROJECT_ROOT, "figures"))
);
app.use(
  "/results",
  express.static(path.join(PROJECT_ROOT, "results"))
);

function sendSuccess(
  res,
  {
    stage,
    message,
    data = null,
    state = "completed",
    httpStatus = 200
  }
) {
  return res.status(httpStatus).json({
    ok: true,
    status: "ok",
    state,
    stage,
    message,
    data,
    error: null,
    meta: {
      timestamp: new Date().toISOString()
    }
  });
}

function sendReviewRequired(
  res,
  {
    stage,
    message,
    data = null
  }
) {
  return res.status(409).json({
    ok: false,
    status: "review_required",
    state: "review_required",
    stage,
    message,
    data,
    error: null,
    meta: {
      timestamp: new Date().toISOString()
    }
  });
}

function sendError(
  res,
  {
    stage,
    code,
    message,
    details = null,
    httpStatus = 500
  }
) {
  return res.status(httpStatus).json({
    ok: false,
    status: "error",
    state: "failed",
    stage,
    message,
    data: null,
    error: {
      code,
      details
    },
    meta: {
      timestamp: new Date().toISOString()
    }
  });
}

// frontend 靜態頁
app.use(express.static(path.join(__dirname, "..", "frontend")));

function parseTsv(content) {
  const trimmed = String(content ?? "").trim();
  if (trimmed === "") return [];

  const lines = trimmed.split(/\r?\n/);
  const headers = lines[0].split("\t");

  return lines.slice(1).map((line) => {
    const values = line.split("\t");
    const row = {};
    headers.forEach((header, i) => {
      row[header] = values[i] ?? "";
    });
    return row;
  });
}

function toTsv(rows, headers) {
  const lines = [headers.join("\t")];

  rows.forEach((row) => {
    const values = headers.map((h) => String(row[h] ?? ""));
    lines.push(values.join("\t"));
  });

  return lines.join("\n");
}

function normalizeInclude(value) {
  const normalized = String(value ?? "").trim().toUpperCase();
  if (normalized === "TRUE") return "TRUE";
  if (normalized === "FALSE") return "FALSE";
  return "";
}

function normalizeCaseControl(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (normalized === "case") return "case";
  if (normalized === "control") return "control";
  return "";
}

function buildDecisionRows(rows) {
  return rows.map((row) => ({
    sample_id: String(row.sample_id ?? "").trim(),
    include: normalizeInclude(row.include_edit),
    group_label: String(row.group_label_edit ?? "").trim(),
    case_control: normalizeCaseControl(row.case_control_edit),
    reason_exclude: String(row.reason_exclude_edit ?? "").trim()
  }));
}

function readSampleIdsFromTsv(tsvPath) {
  if (!fs.existsSync(tsvPath)) {
    throw new Error(`Raw metadata not found: ${tsvPath}`);
  }

  const content = fs.readFileSync(tsvPath, "utf8").trim();
  const lines = content.split(/\r?\n/);

  if (lines.length === 0) {
    throw new Error(`Empty TSV: ${tsvPath}`);
  }

  const headers = lines[0].split("\t");
  const sampleIdIdx = headers.indexOf("sample_id");

  if (sampleIdIdx === -1) {
    throw new Error(`sample_id column not found in: ${tsvPath}`);
  }

  return lines
    .slice(1)
    .map((line) => line.split("\t")[sampleIdIdx] ?? "")
    .map((x) => String(x).trim())
    .filter((x) => x !== "");
}

function readTextIfExists(filePath) {
  if (!fs.existsSync(filePath)) return null;
  return fs.readFileSync(filePath, "utf8");
}

function readJsonIfExists(filePath) {
  if (!fs.existsSync(filePath)) return null;

  const content = fs.readFileSync(filePath, "utf8");
  return JSON.parse(content);
}

function summarizeExecutionFailure(runResult) {
  const text = [
    runResult.stderr,
    runResult.stdout,
    runResult.message
  ]
    .filter(Boolean)
    .join("\n");

  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  const explicitError = lines.find((line) =>
    /^Error(:|\s)/i.test(line)
  );

  return explicitError || lines.at(-1) || "Rscript execution failed.";
}

function technicalDetails(runResult, debug = false) {
  if (!debug) {
    return {
      exitCode: runResult.exitCode
    };
  }

  return {
    exitCode: runResult.exitCode,
    stdout: runResult.stdout,
    stderr: runResult.stderr
  };
}

function computeDatasetSignature(sampleIds) {
  return crypto
    .createHash("sha1")
    .update(sampleIds.join("\n"), "utf8")
    .digest("hex");
}

function validateRowsAgainstRawMetadata(rows, rawMetaPath, clientDatasetSignature) {
  const rawSampleIds = readSampleIdsFromTsv(rawMetaPath);
  const rawSet = new Set(rawSampleIds);

  const rowSampleIds = rows
    .map((r) => String(r.sample_id ?? "").trim())
    .filter((x) => x !== "");

  const rowSet = new Set(rowSampleIds);
  const duplicates = rowSampleIds.filter((id, idx) => rowSampleIds.indexOf(id) !== idx);
  const duplicateUnique = [...new Set(duplicates)];
  const unknownInRows = [...rowSet].filter((id) => !rawSet.has(id));
  const missingFromRows = rawSampleIds.filter((id) => !rowSet.has(id));
  const serverSignature = computeDatasetSignature(rawSampleIds);

  if (clientDatasetSignature && clientDatasetSignature !== serverSignature) {
    return {
      ok: false,
      message:
        `Dataset signature mismatch.\n` +
        `Client loaded a different dataset state than target raw metadata.\n` +
        `Expected signature: ${serverSignature}\n` +
        `Client signature: ${clientDatasetSignature}`
    };
  }

  if (duplicateUnique.length > 0) {
    return {
      ok: false,
      message:
        `Duplicate sample_id detected in UI rows.\n` +
        `Examples: ${duplicateUnique.slice(0, 10).join(", ")}`
    };
  }

  if (unknownInRows.length > 0) {
    return {
      ok: false,
      message:
        `UI rows contain sample_id not present in target raw metadata.\n` +
        `Examples: ${unknownInRows.slice(0, 10).join(", ")}`
    };
  }

  if (missingFromRows.length > 0) {
    return {
      ok: false,
      message:
        `UI rows do not fully cover target raw metadata.\n` +
        `Missing sample_id examples: ${missingFromRows.slice(0, 10).join(", ")}`
    };
  }

  return {
    ok: true,
    serverSignature,
    rawSampleCount: rawSampleIds.length
  };
}

// V1 DEG currently supports exactly two included groups and requires one case and one control group.
function validateCaseControlForV1(decisionRows) {
  const includedRows = decisionRows.filter((row) => row.include === "TRUE");

  if (includedRows.length === 0) {
    return { ok: false, message: "No included samples. Set include=TRUE before Export + Merge." };
  }

  const missingGroup = includedRows.filter((row) => row.group_label === "");
  if (missingGroup.length > 0) {
    return {
      ok: false,
      message:
        "Included samples are missing group_label.\n" +
        `Examples: ${missingGroup.slice(0, 10).map((row) => row.sample_id).join(", ")}`
    };
  }

  const missingRole = includedRows.filter((row) => row.case_control === "");
  if (missingRole.length > 0) {
    return {
      ok: false,
      message:
        "Included samples are missing case_control. Assign each included group as case or control.\n" +
        `Examples: ${missingRole.slice(0, 10).map((row) => row.sample_id).join(", ")}`
    };
  }

  const invalidRole = includedRows.filter(
    (row) => !["case", "control"].includes(row.case_control)
  );
  if (invalidRole.length > 0) {
    return {
      ok: false,
      message:
        "case_control must be either case or control for included samples.\n" +
        `Examples: ${invalidRole.slice(0, 10).map((row) => row.sample_id).join(", ")}`
    };
  }

  const groups = [...new Set(includedRows.map((row) => row.group_label))];
  if (groups.length !== 2) {
    return {
      ok: false,
      message:
        `V1 two-group mode requires exactly 2 included group_label levels. Found ${groups.length}: ` +
        groups.join(", ")
    };
  }

  const groupToRoles = new Map();
  groups.forEach((group) => groupToRoles.set(group, new Set()));
  includedRows.forEach((row) => groupToRoles.get(row.group_label).add(row.case_control));

  const inconsistentGroups = groups.filter((group) => groupToRoles.get(group).size !== 1);
  if (inconsistentGroups.length > 0) {
    return {
      ok: false,
      message:
        "Each group_label must map to exactly one case_control role.\n" +
        `Inconsistent groups: ${inconsistentGroups.join(", ")}`
    };
  }

  const roleByGroup = Object.fromEntries(
    groups.map((group) => [group, [...groupToRoles.get(group)][0]])
  );
  const roles = Object.values(roleByGroup);

  if (!roles.includes("case") || !roles.includes("control")) {
    return {
      ok: false,
      message:
        "The two included groups must be assigned to different roles: one case and one control."
    };
  }

  return { ok: true, roleByGroup };
}

function hydrateExistingCaseControl(rows, decisionPath) {
  const candidateHasCaseControlExisting = rows.some((row) =>
    Object.prototype.hasOwnProperty.call(row, "case_control_existing")
  );

  if (!fs.existsSync(decisionPath)) {
    return {
      rows: rows.map((row) => ({
        ...row,
        case_control_existing: normalizeCaseControl(row.case_control_existing)
      })),
      candidateHasCaseControlExisting,
      caseControlSource: candidateHasCaseControlExisting ? "candidate_builder" : "none"
    };
  }

  const decisionRows = parseTsv(fs.readFileSync(decisionPath, "utf8"));
  const decisionBySample = new Map(
    decisionRows.map((row) => [String(row.sample_id ?? "").trim(), row])
  );

  let fallbackUsed = false;
  const hydratedRows = rows.map((row) => {
    const sampleId = String(row.sample_id ?? "").trim();
    const candidateValue = normalizeCaseControl(row.case_control_existing);
    const decisionValue = normalizeCaseControl(decisionBySample.get(sampleId)?.case_control);
    const resolvedValue = candidateValue || decisionValue;

    if (!candidateValue && decisionValue) fallbackUsed = true;

    return {
      ...row,
      case_control_existing: resolvedValue
    };
  });

  return {
    rows: hydratedRows,
    candidateHasCaseControlExisting,
    caseControlSource: fallbackUsed
      ? "decision_file_fallback"
      : candidateHasCaseControlExisting
        ? "candidate_builder"
        : "none"
  };
}

function verifyMergedCaseControl(mergedPath) {
  if (!fs.existsSync(mergedPath)) {
    return { ok: false, message: `Merged metadata not generated: ${mergedPath}` };
  }

  const mergedRows = parseTsv(fs.readFileSync(mergedPath, "utf8"));
  if (mergedRows.length === 0) {
    return { ok: false, message: `Merged metadata is empty: ${mergedPath}` };
  }

  if (!Object.prototype.hasOwnProperty.call(mergedRows[0], "case_control")) {
    return {
      ok: false,
      message:
        "sample_metadata_merged.tsv does not contain case_control. " +
        "Update 02_merge_decision_resolution.R so it carries case_control from " +
        "sample_metadata_decision.tsv into the merged output."
    };
  }

  const includedRows = mergedRows.filter(
    (row) => normalizeInclude(row.include) === "TRUE"
  );
  const missingRole = includedRows.filter(
    (row) => normalizeCaseControl(row.case_control) === ""
  );

  if (missingRole.length > 0) {
    return {
      ok: false,
      message:
        "Merged metadata contains empty case_control for included samples.\n" +
        `Examples: ${missingRole.slice(0, 10).map((row) => row.sample_id).join(", ")}`
    };
  }

  return { ok: true };
}

function buildProjectPaths(gse, out) {
  const projectRoot = PROJECT_ROOT;
  const outDir = path.join(projectRoot, out);
  const validationOutDir = path.join(projectRoot, "results", gse, "decision_validation");
  const figuresDir = path.join(projectRoot, "figures", gse);
  const resultsDir = path.join(projectRoot, "results", gse);

  return {
    projectRoot,
    outDir,
    validationOutDir,
    metaRawPath: path.join(outDir, "sample_metadata_raw.tsv"),
    decisionPath: path.join(outDir, "sample_metadata_decision.tsv"),
    overridePath: path.join(outDir, "sample_metadata_override.tsv"),
    qcPath: path.join(outDir, "sample_qc_flags.tsv"),
    candidatesPath: path.join(outDir, "sample_metadata_decision_candidates.tsv"),
    mergedPath: path.join(outDir, "sample_metadata_merged.tsv"),
    exprPath: path.join(outDir, "expression_gene_log.tsv"),
    v0RunnerPath: path.join(projectRoot, "V0_data_ingest", "99_run_V0.R"),
    v0EngineeringDir: path.join(outDir, "_engineering"),
    v0GatePath: path.join(outDir, "_engineering", "missingness_gate.json"),
    v0MissingnessReportPath: path.join(outDir, "_engineering", "gene_missingness.tsv"),
    v0SummaryPath: path.join(outDir, "_engineering", "V0_summary.txt"),
    v0ManifestPath: path.join(outDir, "_engineering", "run_manifest.txt"),

    v1RunnerPath: path.join(projectRoot, "V1_analysis", "scripts", "99_run_all.R"),
    v1ScriptsDir: path.join(projectRoot, "V1_analysis", "scripts"),
    figuresDir,
    resultsDir,

    pcaPath: path.join(figuresDir, "PCA.png"),
    distanceHeatmapPath: path.join(figuresDir, "sample_distance_heatmap.png"),
    expressionBoxplotPath: path.join(figuresDir, "expression_boxplot.png"),
    volcanoPath: path.join(figuresDir, "Volcano.png"),
    maPlotPath: path.join(figuresDir, "MA.png"),

    qcGroupCountsPath: path.join(resultsDir, "qc_dataset_overview", "group_counts.tsv"),
    qcRunlogPath: path.join(resultsDir, "qc_dataset_overview", "runlog.txt"),
    qcManifestPath: path.join(resultsDir, "qc_dataset_overview", "manifest.json"),

    degTablePath: path.join(resultsDir, "deg", "topTable.tsv"),
    degSummaryPath: path.join(resultsDir, "deg", "deg_summary.txt"),
    degManifestPath: path.join(resultsDir, "deg", "manifest.json"),

    volcanoPointsPath: path.join(resultsDir, "volcano", "Volcano_points_marked.tsv"),
    volcanoManifestPath: path.join(resultsDir, "volcano", "manifest.json"),

    maPointsPath: path.join(resultsDir, "ma_plot", "MA_points_marked.tsv"),
    maRunlogPath: path.join(resultsDir, "ma_plot", "runlog.txt"),
    maManifestPath: path.join(resultsDir, "ma_plot", "manifest.json"),

    validationSummaryPath: path.join(validationOutDir, "decision_validation_summary.tsv"),
    validationLogPath: path.join(validationOutDir, "decision_validation_log.txt"),
    buildCandidatesScriptPath: path.join(projectRoot, "decision_layer", "01_build_decision_candidates.R"),
    mergeScriptPath: path.join(projectRoot, "decision_layer", "02_merge_decision_resolution.R"),
    validateScriptPath: path.join(projectRoot, "decision_layer", "03_validate_decision_outputs.R")
  };
}

function runRscriptSync(
  scriptPath,
  args,
  {
    cwd, executablePath
  } = {}
) {
  try {
    const stdout = execFileSync(
      executablePath,
      [scriptPath, ...args],
      {
        cwd,
        env: analysisEnvironment(cwd),
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
        maxBuffer: 20 * 1024 * 1024
      }
    );

    return {
      ok: true,
      exitCode: 0,
      stdout: String(stdout ?? ""),
      stderr: "",
      message: ""
    };
  } catch (error) {
    const stdout = error.stdout ? String(error.stdout) : "";
    const stderr = error.stderr ? String(error.stderr) : "";
    const exitCode = Number.isInteger(error.status) ? error.status : 1;
    const message = stderr || stdout || error.message || "Rscript execution failed.";

    return {
      ok: false,
      exitCode,
      stdout,
      stderr,
      message
    };
  }
}

app.get("/api/health", (req, res) => {
  res.json({ status: "ok" });
});

function checkR(req, res, next) {
  const runtime = preflight();
  res.locals.rRuntime = runtime;
  if (!runtime.ok) {
    return sendError(res, {
      stage: "r_preflight", code: runtime.error.code,
      message: runtime.error.message, details: runtime, httpStatus: 503
    });
  }
  next();
}

app.get("/api/preflight/r", checkR, (req, res) => {
  sendSuccess(res, {
    stage: "r_preflight", message: "R is available.", data: res.locals.rRuntime
  });
});

function sendEnvironmentFailure(res, result) {
  return sendError(res, {
    stage: "package_environment", code: result.error?.code || "PACKAGE_ENV_NOT_READY",
    message: result.error?.message || "R package setup is in progress. Wait and retry.",
    details: result, httpStatus: 503
  });
}

async function checkPackages(req, res, next) {
  const result = await environment.inspect(res.locals.rRuntime);
  if (!result.ok) return sendEnvironmentFailure(res, result);
  next();
}

app.get("/api/environment", checkR, async (req, res) => {
  const result = environment.isBusy() ? environment.status() : await environment.inspect(res.locals.rRuntime);
  if (!result.ok) return sendEnvironmentFailure(res, result);
  sendSuccess(res, { stage: "package_environment", message: "R package environment is Ready.", data: result });
});

// An explicit repair returns immediately; analysis routes never call setup.
app.post("/api/environment/setup", checkR, (req, res) => {
  environment.setup(res.locals.rRuntime);
  sendSuccess(res, {
    stage: "package_environment", message: "R package setup requested. Check /api/environment for progress.",
    state: "setting_up", data: environment.status(), httpStatus: 202
  });
});

app.locals.setupEnvironment = () => environment.setup(preflight());

// Check before any R-backed route can modify files. Re-probe on each request so
// installing/repairing R takes effect without restarting the browser or server.
app.post([
  "/api/v0/run", "/api/v1/run", "/api/project/load",
  "/api/decision/export-and-merge", "/api/decision/run-validation"
], checkR, checkPackages);

app.post("/api/v0/run", (req, res) => {
  try {
    const {
      gse,
      max_missing_gene_fraction = 0.05
    } = req.body ?? {};

    const normalizedGse = String(gse ?? "").trim();
    const threshold = Number(max_missing_gene_fraction);

    if (!normalizedGse) {
      return sendError(res, {
        stage: "v0",
        code: "MISSING_GSE",
        message: "Missing gse.",
        httpStatus: 400
      });
    }

    if (!/^GSE\d+$/i.test(normalizedGse)) {
      return sendError(res, {
        stage: "v0",
        code: "INVALID_GSE",
        message: "gse must look like GSE10288.",
        httpStatus: 400
      });
    }

    if (
      !Number.isFinite(threshold) ||
      threshold < 0 ||
      threshold > 1
    ) {
      return sendError(res, {
        stage: "v0",
        code: "INVALID_MISSING_GENE_THRESHOLD",
        message: "max_missing_gene_fraction must be between 0 and 1.",
        httpStatus: 400
      });
    }

    const canonicalGse = normalizedGse.toUpperCase();
    const out = path.join("data_processed", canonicalGse);
    const paths = buildProjectPaths(canonicalGse, out);

    if (!fs.existsSync(paths.v0RunnerPath)) {
      return sendError(res, {
        stage: "v0",
        code: "V0_RUNNER_NOT_FOUND",
        message: `V0 runner not found: ${paths.v0RunnerPath}`,
        httpStatus: 500
      });
    }

    // Remove the prior gate so an unrelated early failure cannot be
    // misclassified using stale review state from an older run.
    if (fs.existsSync(paths.v0GatePath)) {
      fs.unlinkSync(paths.v0GatePath);
    }

    const runResult = runRscriptSync(
      paths.v0RunnerPath,
      [
        "--gse", canonicalGse,
        "--max_missing_gene_fraction", String(threshold)
      ],
      {
        cwd: paths.projectRoot, executablePath: res.locals.rRuntime.selected.executablePath
      }
    );

    let gate = null;

    try {
      gate = readJsonIfExists(paths.v0GatePath);
    } catch (error) {
      return sendError(res, {
        stage: "v0",
        code: "INVALID_V0_GATE_JSON",
        message: `Unable to parse V0 missingness gate: ${paths.v0GatePath}`,
        details: {
          parseError: error.message,
          exitCode: runResult.exitCode,
          stdout: runResult.stdout,
          stderr: runResult.stderr
        },
        httpStatus: 500
      });
    }

    if (!runResult.ok) {
      if (gate?.status === "review_required") {
        return sendReviewRequired(res, {
          stage: "v0_missingness_gate",
          message:
            "V0 stopped because post-aggregation gene missingness exceeded the configured threshold.",
          data: {
            gse: canonicalGse,
            gate,
            outputs: {
              missingness_report: paths.v0MissingnessReportPath,
              missingness_gate: paths.v0GatePath
            },
            technical: {
              exitCode: runResult.exitCode,
              stdout: runResult.stdout,
              stderr: runResult.stderr
            }
          }
        });
      }

      return sendError(res, {
        stage: "v0",
        code: "V0_EXECUTION_FAILED",
        message: runResult.message,
        details: {
          exitCode: runResult.exitCode,
          stdout: runResult.stdout,
          stderr: runResult.stderr,
          gate
        },
        httpStatus: 500
      });
    }

    if (!gate) {
      return sendError(res, {
        stage: "v0",
        code: "V0_GATE_NOT_WRITTEN",
        message:
          "V0 completed, but missingness_gate.json was not generated. " +
          "The V0 runner and API contract are out of sync.",
        details: {
          expectedPath: paths.v0GatePath,
          stdout: runResult.stdout
        },
        httpStatus: 500
      });
    }

    if (gate.status !== "passed") {
      return sendError(res, {
        stage: "v0",
        code: "UNEXPECTED_V0_GATE_STATUS",
        message: `V0 returned an unexpected gate status: ${gate.status}`,
        details: {
          gate,
          stdout: runResult.stdout,
          stderr: runResult.stderr
        },
        httpStatus: 500
      });
    }

    return sendSuccess(res, {
      stage: "v0",
      message: "V0 completed successfully.",
      data: {
        gse: canonicalGse,
        parameters: {
          max_missing_gene_fraction: threshold
        },
        gate,
        outputs: {
          expression: paths.exprPath,
          raw_metadata: paths.metaRawPath,
          decision_template: paths.decisionPath,
          missingness_report: paths.v0MissingnessReportPath,
          missingness_gate: paths.v0GatePath,
          summary: paths.v0SummaryPath,
          manifest: paths.v0ManifestPath
        },
        technical: {
          exitCode: runResult.exitCode,
          stdout: runResult.stdout,
          stderr: runResult.stderr
        }
      }
    });
  } catch (error) {
    console.error(error);

    return sendError(res, {
      stage: "v0",
      code: "UNEXPECTED_ERROR",
      message: error.message,
      httpStatus: 500
    });
  }
});

app.post("/api/v1/run", (req, res) => {
  try {
    const {
      gse,
      padj_cutoff = 0.05,
      lfc_cutoff = 1,
      run_mode = "full",
      debug = false
    } = req.body ?? {};

    const normalizedGse = String(gse ?? "").trim();
    const padj = Number(padj_cutoff);
    const lfc = Number(lfc_cutoff);
    const normalizedRunMode = String(run_mode ?? "").trim().toLowerCase();
    const debugEnabled = debug === true;

    if (!normalizedGse) {
      return sendError(res, {
        stage: "v1",
        code: "MISSING_GSE",
        message: "Missing gse.",
        httpStatus: 400
      });
    }

    if (!/^GSE\d+$/i.test(normalizedGse)) {
      return sendError(res, {
        stage: "v1",
        code: "INVALID_GSE",
        message: "gse must look like GSE10288.",
        httpStatus: 400
      });
    }

    if (
      !Number.isFinite(padj) ||
      padj <= 0 ||
      padj > 1
    ) {
      return sendError(res, {
        stage: "v1",
        code: "INVALID_PADJ_CUTOFF",
        message: "padj_cutoff must be greater than 0 and less than or equal to 1.",
        httpStatus: 400
      });
    }

    if (
      !Number.isFinite(lfc) ||
      lfc < 0
    ) {
      return sendError(res, {
        stage: "v1",
        code: "INVALID_LFC_CUTOFF",
        message: "lfc_cutoff must be greater than or equal to 0.",
        httpStatus: 400
      });
    }

    if (!["full", "thresholds_only"].includes(normalizedRunMode)) {
      return sendError(res, {
        stage: "v1",
        code: "INVALID_RUN_MODE",
        message: "run_mode must be either full or thresholds_only.",
        httpStatus: 400
      });
    }

    const canonicalGse = normalizedGse.toUpperCase();
    const out = path.join("data_processed", canonicalGse);
    const paths = buildProjectPaths(canonicalGse, out);

    if (!fs.existsSync(paths.v1RunnerPath)) {
      return sendError(res, {
        stage: "v1",
        code: "V1_RUNNER_NOT_FOUND",
        message: `V1 runner not found: ${paths.v1RunnerPath}`,
        httpStatus: 500
      });
    }

    if (!fs.existsSync(paths.exprPath)) {
      return sendError(res, {
        stage: "v1",
        code: "EXPRESSION_NOT_FOUND",
        message: `Canonical expression not found: ${paths.exprPath}`,
        httpStatus: 422
      });
    }

    if (!fs.existsSync(paths.mergedPath)) {
      return sendError(res, {
        stage: "v1",
        code: "MERGED_METADATA_NOT_FOUND",
        message: `Merged metadata not found: ${paths.mergedPath}`,
        httpStatus: 422
      });
    }

    const args = [
      "--gse", canonicalGse,
      "--scripts_dir", paths.v1ScriptsDir,
      "--rscript", res.locals.rRuntime.selected.executablePath,
      "--padj_cutoff", String(padj),
      "--lfc_cutoff", String(lfc)
    ];

    if (normalizedRunMode === "thresholds_only") {
      args.push("--skip_qc");
    }

    const runResult = runRscriptSync(
      paths.v1RunnerPath,
      args,
      {
        cwd: paths.projectRoot, executablePath: res.locals.rRuntime.selected.executablePath
      }
    );

    if (!runResult.ok) {
      const conciseMessage = summarizeExecutionFailure(runResult);

      return sendError(res, {
        stage: "v1",
        code: "V1_EXECUTION_FAILED",
        message: conciseMessage,
        details: technicalDetails(runResult, debugEnabled),
        httpStatus: 500
      });
    }

    const requiredOutputs = {
      deg_table: paths.degTablePath,
      volcano: paths.volcanoPath,
      ma_plot: paths.maPlotPath
    };

    if (normalizedRunMode === "full") {
      requiredOutputs.pca = paths.pcaPath;
      requiredOutputs.distance_heatmap = paths.distanceHeatmapPath;
      requiredOutputs.expression_boxplot = paths.expressionBoxplotPath;
    }

    const missingOutputs = Object.entries(requiredOutputs)
      .filter(([, filePath]) => !fs.existsSync(filePath))
      .map(([name, filePath]) => ({
        name,
        path: filePath
      }));

    if (missingOutputs.length > 0) {
      return sendError(res, {
        stage: "v1",
        code: "V1_OUTPUTS_INCOMPLETE",
        message: "V1 completed without all expected output files.",
        details: {
          missingOutputs,
          ...technicalDetails(runResult, debugEnabled)
        },
        httpStatus: 500
      });
    }

    const cacheBust = Date.now();

    return sendSuccess(res, {
      stage: "v1",
      message: "V1 completed successfully.",
      data: {
        gse: canonicalGse,
        run_mode: normalizedRunMode,
        parameters: {
          padj_cutoff: padj,
          lfc_cutoff: lfc
        },
        outputs: {
          figures: {
            pca:
              `/figures/${canonicalGse}/PCA.png?v=${cacheBust}`,
            distance_heatmap:
              `/figures/${canonicalGse}/sample_distance_heatmap.png?v=${cacheBust}`,
            expression_boxplot:
              `/figures/${canonicalGse}/expression_boxplot.png?v=${cacheBust}`,
            volcano:
              `/figures/${canonicalGse}/Volcano.png?v=${cacheBust}`,
            ma_plot:
              `/figures/${canonicalGse}/MA.png?v=${cacheBust}`
          },
          results: {
            qc_group_counts:
              `/results/${canonicalGse}/qc_dataset_overview/group_counts.tsv`,
            qc_runlog:
              `/results/${canonicalGse}/qc_dataset_overview/runlog.txt`,
            qc_manifest:
              `/results/${canonicalGse}/qc_dataset_overview/manifest.json`,
            deg_table:
              `/results/${canonicalGse}/deg/topTable.tsv`,
            deg_summary:
              `/results/${canonicalGse}/deg/deg_summary.txt`,
            deg_manifest:
              `/results/${canonicalGse}/deg/manifest.json`,
            volcano_points:
              `/results/${canonicalGse}/volcano/Volcano_points_marked.tsv`,
            volcano_manifest:
              `/results/${canonicalGse}/volcano/manifest.json`,
            ma_points:
              `/results/${canonicalGse}/ma_plot/MA_points_marked.tsv`,
            ma_runlog:
              `/results/${canonicalGse}/ma_plot/runlog.txt`,
            ma_manifest:
              `/results/${canonicalGse}/ma_plot/manifest.json`
          }
        },
        technical: technicalDetails(runResult, debugEnabled)
      }
    });
  } catch (error) {
    console.error(error);

    return sendError(res, {
      stage: "v1",
      code: "UNEXPECTED_ERROR",
      message: error.message,
      httpStatus: 500
    });
  }
});

app.post("/api/project/load", (req, res) => {
  try {
    const { gse, out } = req.body;

    if (!gse || !out) {
      return res.status(400).json({ status: "error", message: "Missing gse or out" });
    }

    const paths = buildProjectPaths(gse, out);

    if (!fs.existsSync(paths.buildCandidatesScriptPath)) {
      return res.status(500).json({
        status: "error",
        message: `Cannot find R script: ${paths.buildCandidatesScriptPath}`
      });
    }

    const args = [
      "--gse", gse,
      "--meta_raw", paths.metaRawPath,
      "--out", paths.outDir
    ];

    if (fs.existsSync(paths.decisionPath)) args.push("--decision", paths.decisionPath);
    if (fs.existsSync(paths.overridePath)) args.push("--override", paths.overridePath);
    if (fs.existsSync(paths.qcPath)) args.push("--qc", paths.qcPath);

    const runResult = runRscriptSync(
      paths.buildCandidatesScriptPath,
      args,
      { cwd: paths.projectRoot, executablePath: res.locals.rRuntime.selected.executablePath }
    );

    if (!runResult.ok) {
      return res.status(500).json({ status: "error", message: runResult.message });
    }

    if (!fs.existsSync(paths.candidatesPath)) {
      return res.status(500).json({
        status: "error",
        message: `Candidates file not generated: ${paths.candidatesPath}`
      });
    }

    const candidateRows = parseTsv(fs.readFileSync(paths.candidatesPath, "utf8"));
    const caseControlHydration = hydrateExistingCaseControl(
      candidateRows,
      paths.decisionPath
    );
    const rows = caseControlHydration.rows;

    const rawSampleIds = readSampleIdsFromTsv(paths.metaRawPath);
    const datasetSignature = computeDatasetSignature(rawSampleIds);

    res.json({
      status: "ok",
      gse,
      n_samples: rows.length,
      columns: rows.length > 0 ? Object.keys(rows[0]) : [],
      rows,
      diagnostics: {
        candidate_has_case_control_existing:
          caseControlHydration.candidateHasCaseControlExisting,
        case_control_existing_source: caseControlHydration.caseControlSource
      },
      loaded: {
        gse,
        out,
        datasetSignature,
        rawSampleCount: rawSampleIds.length,
        candidatesPath: paths.candidatesPath,
        rawMetaPath: paths.metaRawPath,
        decisionPath: paths.decisionPath,
        overridePath: paths.overridePath,
        qcPath: paths.qcPath,
        candidateHasCaseControlExisting:
          caseControlHydration.candidateHasCaseControlExisting,
        caseControlExistingSource: caseControlHydration.caseControlSource
      }
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({ status: "error", message: error.message });
  }
});

app.post("/api/decision/save", (req, res) => {
  try {
    const { gse, out, rows, datasetSignature } = req.body;

    if (!gse || !out || !Array.isArray(rows)) {
      return res.status(400).json({
        status: "error",
        message: "Missing gse, out, or rows"
      });
    }

    const paths = buildProjectPaths(gse, out);
    const validation = validateRowsAgainstRawMetadata(
      rows,
      paths.metaRawPath,
      datasetSignature
    );

    if (!validation.ok) {
      return res.status(400).json({ status: "error", message: validation.message });
    }

    const decisionRows = buildDecisionRows(rows);
    const headers = [
      "sample_id",
      "include",
      "group_label",
      "case_control",
      "reason_exclude"
    ];

    fs.writeFileSync(paths.decisionPath, toTsv(decisionRows, headers), "utf8");

    res.json({
      status: "ok",
      message: "Decision table saved",
      output_path: paths.decisionPath,
      n_rows: decisionRows.length,
      datasetSignature: validation.serverSignature
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({ status: "error", message: error.message });
  }
});

app.post("/api/decision/export-and-merge", (req, res) => {
  try {
    const { gse, out, rows, datasetSignature } = req.body;

    if (!gse || !out || !Array.isArray(rows)) {
      return res.status(400).json({
        status: "error",
        message: "Missing gse, out, or rows"
      });
    }

    const paths = buildProjectPaths(gse, out);
    const validation = validateRowsAgainstRawMetadata(
      rows,
      paths.metaRawPath,
      datasetSignature
    );

    if (!validation.ok) {
      return res.status(400).json({ status: "error", message: validation.message });
    }

    const decisionRows = buildDecisionRows(rows);
    const caseControlValidation = validateCaseControlForV1(decisionRows);

    if (!caseControlValidation.ok) {
      return res.status(400).json({
        status: "error",
        message: caseControlValidation.message
      });
    }

    const headers = [
      "sample_id",
      "include",
      "group_label",
      "case_control",
      "reason_exclude"
    ];

    fs.writeFileSync(paths.decisionPath, toTsv(decisionRows, headers), "utf8");

    const args = [
      "--gse", gse,
      "--meta_raw", paths.metaRawPath,
      "--decision", paths.decisionPath,
      "--out", paths.outDir
    ];

    if (fs.existsSync(paths.overridePath)) args.push("--override", paths.overridePath);
    if (fs.existsSync(paths.qcPath)) args.push("--qc", paths.qcPath);

    const runResult = runRscriptSync(
      paths.mergeScriptPath,
      args,
      { cwd: paths.projectRoot, executablePath: res.locals.rRuntime.selected.executablePath }
    );

    if (!runResult.ok) {
      return res.status(500).json({ status: "error", message: runResult.message });
    }

    const mergedVerification = verifyMergedCaseControl(paths.mergedPath);
    if (!mergedVerification.ok) {
      return res.status(500).json({
        status: "error",
        message: mergedVerification.message
      });
    }

    res.json({
      status: "ok",
      message: "Decision exported and merged successfully",
      decision_path: paths.decisionPath,
      merged_path: paths.mergedPath,
      case_control_mapping: caseControlValidation.roleByGroup,
      datasetSignature: validation.serverSignature
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({ status: "error", message: error.message });
  }
});

app.post("/api/decision/run-validation", (req, res) => {
  try {
    const { gse, out } = req.body;

    if (!gse || !out) {
      return res.status(400).json({ status: "error", message: "Missing gse or out" });
    }

    const paths = buildProjectPaths(gse, out);

    if (!fs.existsSync(paths.validateScriptPath)) {
      return res.status(500).json({
        status: "error",
        message: `Validation script not found: ${paths.validateScriptPath}`
      });
    }

    fs.mkdirSync(paths.validationOutDir, { recursive: true });

    const args = [
      "--gse", gse,
      "--expr", paths.exprPath,
      "--meta_raw", paths.metaRawPath,
      "--decision", paths.decisionPath,
      "--meta", paths.mergedPath,
      "--out", paths.validationOutDir
    ];

    if (fs.existsSync(paths.overridePath)) args.push("--override", paths.overridePath);
    if (fs.existsSync(paths.qcPath)) args.push("--qc", paths.qcPath);

    const runResult = runRscriptSync(
      paths.validateScriptPath,
      args,
      { cwd: paths.projectRoot, executablePath: res.locals.rRuntime.selected.executablePath }
    );

    if (!runResult.ok) {
      return res.status(500).json({ status: "error", message: runResult.message });
    }

    const logText = readTextIfExists(paths.validationLogPath);
    const summaryText = readTextIfExists(paths.validationSummaryPath);

    res.json({
      status: "ok",
      message: "Validation completed",
      validation_summary_path: paths.validationSummaryPath,
      validation_log_path: paths.validationLogPath,
      validation_log_text: logText,
      validation_summary_text: summaryText
    });
  } catch (error) {
    console.error(error);
    res.status(500).json({ status: "error", message: error.message });
  }
});

return app;
}

if (require.main === module) {
  const environment = createPackageEnvironment({ onState: (state) => {
    console.log(`[R packages] ${state.state}: ${state.message || state.error?.message || ""}`);
    if (state.logFile) console.log(`[R packages] Log: ${state.logFile}`);
  } });
  const app = createApp({ environment });
  app.listen(3001, () => {
    console.log("Decision UI API running at http://localhost:3001");
    app.locals.setupEnvironment();
  });
}

module.exports = { createApp };
