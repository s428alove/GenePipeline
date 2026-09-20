"use strict";

const appState = {
  stage: "idle",
  gse: "GSE10288",
  v0Gate: null,
  v0Result: null,
  decisionReady: false,
  validationSummary: null,
  v1Result: null,
  error: null
};

let currentRows = [];
let loadedInfo = null;
let isDirty = false;
let groupRoleMap = {};
let activeGroupFilter = "__all__";
let selectedSampleIds = new Set();
let knownGroups = new Set();
let selectionAnchorSampleId = null;
let pendingShiftSelection = false;

const byId = (id) => document.getElementById(id);

document.addEventListener("DOMContentLoaded", () => {
  bindEvents();
  syncDatasetFields();
  setDecisionControlsEnabled(false);
  showRCompatibility();
});

async function showRCompatibility() {
  const notice = byId("rCompatibilityNotice");
  try {
    const response = await fetch("/api/preflight/r");
    const result = await response.json();
    const warning = result.data?.compatibility?.warning;
    if (warning || !response.ok) {
      notice.textContent = warning || result.message;
      notice.hidden = false;
    }
  } catch {
    notice.textContent = "R compatibility status could not be checked. Check that the GenePipeline server is running.";
    notice.hidden = false;
  }
}

function bindEvents() {
  byId("gse").addEventListener("input", handleGseInput);
  byId("runV0Button").addEventListener("click", () => {
    const threshold = Number(byId("v0Threshold").value);
    runV0(threshold);
  });

  byId("approveGateButton").addEventListener("click", approveMissingnessGate);
  byId("continueDecisionButton").addEventListener("click", continueToDecision);

  byId("loadProjectButton").addEventListener("click", loadProject);
  byId("saveDecisionButton").addEventListener("click", saveDecision);
  byId("exportMergeButton").addEventListener("click", exportAndMerge);
  byId("runValidationButton").addEventListener("click", runValidation);
  byId("continueV1Button").addEventListener("click", continueToV1);
  byId("runV1Button").addEventListener("click", () => runV1("full"));
  byId("continueResultsButton").addEventListener("click", continueToResults);
  byId("rerunThresholdsButton").addEventListener(
    "click",
    () => runV1("thresholds_only")
  );

  byId("createGroupButton").addEventListener("click", createGroup);
  byId("batchGroupSelect").addEventListener("change", updateBatchMoveState);
  byId("batchMoveButton").addEventListener("click", moveSelectedToGroup);
  byId("batchExcludeButton").addEventListener("click", excludeSelected);
  byId("batchUnassignButton").addEventListener("click", unassignSelected);
  byId("clearSelectionButton").addEventListener("click", clearSelection);

  document.querySelectorAll(".nav-step").forEach((button) => {
    button.addEventListener("click", () => {
      if (button.disabled) return;

      const stage = button.dataset.stage;
      if (stage === "dataset") {
        showPanel("dataset");
        setStageLabel(
          appState.stage === "v0_review_required"
            ? "V0 review"
            : appState.stage === "v0_completed"
              ? "V0 completed"
              : "Dataset"
        );
      }

      if (stage === "decision") {
        showPanel("decision");
        setStageLabel(
          appState.decisionReady ? "Decision ready" : "Decision"
        );
      }

      if (stage === "v1") {
        showPanel("v1");
        setStageLabel(
          appState.stage === "running_v1"
            ? "Running V1"
            : appState.v1Result
              ? "V1 completed"
              : "V1 Analysis"
        );
      }

      if (stage === "results") {
        showPanel("results");
        setStageLabel("Results");
      }
    });
  });

  byId("groupList").addEventListener("click", (event) => {
    const deleteButton = event.target.closest("[data-delete-group]");

    if (deleteButton) {
      const group = decodeURIComponent(deleteButton.dataset.deleteGroup);
      deleteGroup(group);
      return;
    }

    const renameButton = event.target.closest("[data-rename-group]");

    if (renameButton) {
      const group = decodeURIComponent(renameButton.dataset.renameGroup);
      renameGroup(group);
      return;
    }

    const filterButton = event.target.closest("[data-group-filter]");
    if (!filterButton) return;

    activeGroupFilter = decodeURIComponent(filterButton.dataset.groupFilter);
    selectionAnchorSampleId = null;
    pendingShiftSelection = false;
    renderGroupList();
    renderFilteredTable();
  });

  byId("groupRoleRows").addEventListener("change", (event) => {
    const select = event.target.closest("[data-group-role]");
    if (!select) return;

    const group = decodeURIComponent(select.dataset.groupRole);
    updateGroupRole(group, select.value);
  });

  byId("tableContainer").addEventListener("click", (event) => {
    const rowCheckbox = event.target.closest("[data-select-sample]");

    if (rowCheckbox) {
      pendingShiftSelection = event.shiftKey === true;
    }
  });

  byId("tableContainer").addEventListener("change", (event) => {
    const selectAll = event.target.closest("[data-select-all-visible]");

    if (selectAll) {
      setVisibleSelection(selectAll.checked);
      return;
    }

    const rowCheckbox = event.target.closest("[data-select-sample]");

    if (rowCheckbox) {
      const sampleId = decodeURIComponent(
        rowCheckbox.dataset.selectSample
      );

      if (pendingShiftSelection && selectionAnchorSampleId) {
        setSelectionRange(
          selectionAnchorSampleId,
          sampleId,
          rowCheckbox.checked
        );
      } else {
        setSampleSelection(sampleId, rowCheckbox.checked);
      }

      selectionAnchorSampleId = sampleId;
      pendingShiftSelection = false;
      return;
    }

    const groupInput = event.target.closest("[data-group-row]");

    if (groupInput) {
      commitGroupLabel(
        Number(groupInput.dataset.groupRow),
        groupInput.value
      );
    }
  });
}

function handleGseInput() {
  syncDatasetFields();
  resetV0View();
  resetDecisionState();
  lockNavigationFrom("decision");
}

function syncDatasetFields() {
  const gse = byId("gse").value.trim().toUpperCase();
  appState.gse = gse;
  byId("decisionGse").value = gse;
  byId("out").value = gse ? `data_processed/${gse}` : "";
}

function validateGse(gse) {
  return /^GSE\d+$/i.test(gse);
}

function validateThreshold(value) {
  return Number.isFinite(value) && value >= 0 && value <= 1;
}

function validateV1Parameters(padj, lfc) {
  if (!Number.isFinite(padj) || padj <= 0 || padj > 1) {
    return {
      ok: false,
      message:
        "Adjusted P-value cutoff must be greater than 0 and less than or equal to 1."
    };
  }

  if (!Number.isFinite(lfc) || lfc < 0) {
    return {
      ok: false,
      message: "Absolute log2FC cutoff must be greater than or equal to 0."
    };
  }

  return { ok: true };
}

async function apiPost(url, body) {
  let response;

  try {
    response = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify(body)
    });
  } catch (error) {
    return {
      ok: false,
      status: "error",
      state: "failed",
      httpStatus: 0,
      message: "Unable to connect to the backend server.",
      error: {
        code: "NETWORK_ERROR",
        details: error.message
      }
    };
  }

  let payload;

  try {
    payload = await response.json();
  } catch (error) {
    return {
      ok: false,
      status: "error",
      state: "failed",
      httpStatus: response.status,
      message: "The server returned a response that was not valid JSON.",
      error: {
        code: "INVALID_JSON_RESPONSE",
        details: error.message
      }
    };
  }

  return {
    httpStatus: response.status,
    ...payload
  };
}

async function runV0(threshold) {
  const gse = byId("gse").value.trim().toUpperCase();

  if (!validateGse(gse)) {
    showV0Status("Enter a valid GEO Series accession such as GSE10288.", "error");
    byId("gse").focus();
    return;
  }

  if (!validateThreshold(threshold)) {
    showV0Status("The missing-gene threshold must be between 0 and 1.", "error");
    byId("v0Threshold").focus();
    return;
  }

  syncDatasetFields();
  resetDecisionState();

  appState.stage = "running_v0";
  appState.v0Gate = null;
  appState.v0Result = null;
  appState.error = null;

  hideV0ResultCards();
  setV0Running(true);
  setStageLabel("Running V0");
  showV0Status(
    "Running V0…\nReading expression and annotation data, performing pre-QC, and checking gene-level missingness.",
    "running"
  );

  const result = await apiPost("/api/v0/run", {
    gse,
    max_missing_gene_fraction: threshold
  });

  setV0Running(false);

  if (result.state === "review_required") {
    appState.stage = "v0_review_required";
    appState.v0Gate = result.data?.gate ?? null;
    setStageLabel("V0 review");
    renderMissingnessGate(result);
    return;
  }

  if (result.ok === true && result.state === "completed") {
    appState.stage = "v0_completed";
    appState.v0Result = result.data;
    appState.v0Gate = result.data?.gate ?? null;
    setStageLabel("V0 completed");
    renderV0Complete(result);
    return;
  }

  appState.stage = "failed";
  appState.error = result;
  setStageLabel("V0 failed");
  renderApiError("V0 failed", result, byId("v0Status"));
}

function approveMissingnessGate() {
  const recommended = Number(
    appState.v0Gate?.recommended_minimum_threshold
  );

  if (!validateThreshold(recommended)) {
    showV0Status(
      "The API did not return a valid recommended threshold.",
      "error"
    );
    return;
  }

  byId("v0Threshold").value = String(recommended);
  runV0(recommended);
}

function renderMissingnessGate(result) {
  const gate = result.data?.gate;

  if (!gate) {
    renderApiError(
      "V0 review response is incomplete",
      {
        ...result,
        message: "The backend did not include missingness gate data."
      },
      byId("v0Status")
    );
    return;
  }

  hideV0Status();

  byId("gateGenesBefore").textContent = formatInteger(gate.genes_before);
  byId("gateGenesRemoved").textContent = formatInteger(gate.genes_removed);
  byId("gateGenesAfter").textContent = formatInteger(gate.genes_after);
  byId("gateRemovalRate").textContent = formatPercent(gate.removed_fraction);
  byId("gateCurrentThreshold").textContent = formatPercent(
    gate.configured_threshold
  );
  byId("gateRecommendedThreshold").textContent = formatPercent(
    gate.recommended_minimum_threshold
  );
  byId("gateReportPath").textContent = gate.report_path ?? "Not provided";

  byId("gateExplanation").textContent =
    `${formatInteger(gate.genes_removed)} of ${formatInteger(gate.genes_before)} genes ` +
    `contain non-finite values after probe-to-gene aggregation. ` +
    `The ${formatPercent(gate.removed_fraction)} removal rate exceeds the current ` +
    `${formatPercent(gate.configured_threshold)} threshold.`;

  byId("approveGateButton").textContent =
    `Approve ${formatPercent(gate.recommended_minimum_threshold)} and rerun`;

  byId("missingnessGateCard").hidden = false;
  byId("v0CompleteCard").hidden = true;
}

function renderV0Complete(result) {
  const gate = result.data?.gate;

  hideV0Status();
  byId("missingnessGateCard").hidden = true;

  byId("completeSamples").textContent = formatInteger(gate?.samples);
  byId("completeGenesAfter").textContent = formatInteger(gate?.genes_after);
  byId("completeGenesRemoved").textContent = formatInteger(gate?.genes_removed);
  byId("completeThreshold").textContent = formatPercent(
    gate?.configured_threshold
  );

  byId("v0CompleteCard").hidden = false;
  unlockNavigation("decision");
}

function resetV0View() {
  appState.stage = "idle";
  appState.v0Gate = null;
  appState.v0Result = null;
  appState.error = null;

  hideV0ResultCards();
  hideV0Status();
  setStageLabel("Dataset");
}

function hideV0ResultCards() {
  byId("missingnessGateCard").hidden = true;
  byId("v0CompleteCard").hidden = true;
}

function setV0Running(isRunning) {
  byId("runV0Button").disabled = isRunning;
  byId("approveGateButton").disabled = isRunning;
  byId("gse").disabled = isRunning;
  byId("v0Threshold").disabled = isRunning;
}

function showV0Status(message, type = "default") {
  const box = byId("v0Status");
  box.hidden = false;
  box.className = "status-box";

  if (type === "running") box.classList.add("is-running");
  if (type === "error") box.classList.add("is-error");
  if (type === "success") box.classList.add("is-success");

  box.textContent = message;
}

function hideV0Status() {
  const box = byId("v0Status");
  box.hidden = true;
  box.className = "status-box";
  box.textContent = "";
}

function renderApiError(title, result, target) {
  target.hidden = false;
  target.className = "status-box is-error";

  const code = result.error?.code
    ? `\nError code: ${result.error.code}`
    : "";

  target.textContent =
    `${title}\n${result.message ?? "Unknown error."}${code}`;
}

function setStageLabel(label) {
  byId("pipelineStage").textContent = label;
}

function unlockNavigation(stage) {
  const button = document.querySelector(`[data-stage="${stage}"]`);
  if (button) button.disabled = false;
}

function lockNavigationFrom(stage) {
  const order = ["dataset", "decision", "v1", "results"];
  const startIndex = order.indexOf(stage);

  order.slice(startIndex).forEach((name) => {
    const button = document.querySelector(`[data-stage="${name}"]`);
    if (button) button.disabled = true;
  });
}

async function continueToDecision() {
  showPanel("decision");
  setStageLabel("Decision");
  await loadProject();
}

function showPanel(panelName) {
  byId("datasetPanel").hidden = panelName !== "dataset";
  byId("decisionPanel").hidden = panelName !== "decision";
  byId("v1Panel").hidden = panelName !== "v1";
  byId("resultsPanel").hidden = panelName !== "results";

  document.querySelectorAll(".nav-step").forEach((button) => {
    button.classList.toggle(
      "is-active",
      button.dataset.stage === panelName
    );
  });

  window.scrollTo({
    top: 0,
    behavior: "smooth"
  });
}

function formatInteger(value) {
  const number = Number(value);
  return Number.isFinite(number)
    ? new Intl.NumberFormat().format(number)
    : "—";
}

function formatPercent(value) {
  const number = Number(value);
  return Number.isFinite(number)
    ? `${(number * 100).toFixed(2).replace(/\.?0+$/, "")}%`
    : "—";
}

function normalizeValue(value) {
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

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function resetDecisionState() {
  currentRows = [];
  loadedInfo = null;
  isDirty = false;
  groupRoleMap = {};
  activeGroupFilter = "__all__";
  selectedSampleIds = new Set();
  knownGroups = new Set();
  selectionAnchorSampleId = null;
  pendingShiftSelection = false;

  byId("summary").hidden = true;
  byId("summary").innerHTML = "";

  byId("loadedInfoDetails").hidden = true;
  byId("loadedInfo").textContent = "";

  byId("groupRoleBox").hidden = true;
  byId("groupRoleRows").innerHTML = "";
  byId("groupRoleStatus").innerHTML = "";

  byId("validationBox").hidden = true;
  byId("validationBox").textContent = "";
  byId("decisionReadyCard").hidden = true;

  appState.decisionReady = false;
  appState.validationSummary = null;
  resetV1State();

  byId("decisionWorkspace").hidden = true;
  byId("groupList").innerHTML = "";
  byId("groupTotalCount").textContent = "0";
  byId("sampleTableTitle").textContent = "All samples";
  byId("sampleTableCount").textContent = "0 samples";
  byId("batchToolbar").hidden = true;
  byId("selectedCount").textContent = "0 samples selected";
  byId("batchGroupSelect").innerHTML =
    '<option value="">Move to group…</option>';
  byId("batchMoveButton").disabled = true;
  byId("createGroupButton").disabled = true;
  byId("tableContainer").innerHTML = "";

  hideDecisionStatus();
  setDecisionControlsEnabled(false);
}

function setDecisionControlsEnabled(enabled) {
  byId("saveDecisionButton").disabled = !enabled;
  byId("exportMergeButton").disabled = !enabled;
  byId("runValidationButton").disabled = !enabled;
}

function showDecisionStatus(message, type = "default") {
  const box = byId("decisionStatus");
  box.hidden = false;
  box.className = "status-box";

  if (type === "running") box.classList.add("is-running");
  if (type === "error") box.classList.add("is-error");
  if (type === "success") box.classList.add("is-success");

  box.textContent = message;
}

function hideDecisionStatus() {
  const box = byId("decisionStatus");
  box.hidden = true;
  box.className = "status-box";
  box.textContent = "";
}

function renderLoadedInfo() {
  if (!loadedInfo) {
    byId("loadedInfoDetails").hidden = true;
    byId("loadedInfo").textContent = "";
    return;
  }

  const builderStatus = loadedInfo.candidateHasCaseControlExisting
    ? "Yes"
    : "No";

  byId("loadedInfoDetails").hidden = false;
  byId("loadedInfo").textContent =
`GSE: ${loadedInfo.gse}
Out: ${loadedInfo.out}
Raw metadata: ${loadedInfo.rawMetaPath}
Candidates: ${loadedInfo.candidatesPath}
Decision target: ${loadedInfo.decisionPath}
Override path: ${loadedInfo.overridePath}
QC path: ${loadedInfo.qcPath}
Raw sample count: ${loadedInfo.rawSampleCount}
Dataset signature: ${loadedInfo.datasetSignature}
Candidate builder outputs case_control_existing: ${builderStatus}
Loaded case_control source: ${loadedInfo.caseControlExistingSource}`;
}

function ensureLoadedDatasetMatch() {
  const gse = byId("decisionGse").value.trim();
  const out = byId("out").value.trim();

  if (!loadedInfo) {
    showDecisionStatus("No project is loaded yet.", "error");
    return false;
  }

  if (gse !== loadedInfo.gse || out !== loadedInfo.out) {
    showDecisionStatus(
      "The current fields no longer match the loaded dataset. Reload candidates.",
      "error"
    );
    return false;
  }

  return true;
}

function normalizeGroupName(value) {
  return String(value ?? "").trim();
}

function groupNameKey(value) {
  return normalizeGroupName(value).toLocaleLowerCase();
}

function isReservedGroupName(value) {
  return ["unassigned", "excluded", "all samples"].includes(
    groupNameKey(value)
  );
}

function findKnownGroupByName(value) {
  const key = groupNameKey(value);

  return [...knownGroups].find(
    (group) => groupNameKey(group) === key
  ) ?? null;
}

function validateNewGroupName(value, currentName = null) {
  const name = normalizeGroupName(value);

  if (name === "") {
    return {
      ok: false,
      message: "Group name cannot be empty."
    };
  }

  if (/[\t\r\n]/.test(name)) {
    return {
      ok: false,
      message: "Group name cannot contain tabs or line breaks."
    };
  }

  if (isReservedGroupName(name)) {
    return {
      ok: false,
      message: `"${name}" is reserved by the interface.`
    };
  }

  const existing = findKnownGroupByName(name);
  const sameAsCurrent =
    currentName !== null &&
    groupNameKey(currentName) === groupNameKey(name);

  if (existing && !sameAsCurrent) {
    return {
      ok: false,
      message: `Group "${existing}" already exists.`
    };
  }

  return {
    ok: true,
    name
  };
}

function initializeKnownGroupsFromRows() {
  knownGroups = new Set();

  currentRows.forEach((row) => {
    const include = normalizeValue(row.include_edit);
    const group = normalizeGroupName(row.group_label_edit);

    if (include === "TRUE" && group !== "") {
      knownGroups.add(group);
    }
  });
}

function classifyDecisionRow(row) {
  const include = normalizeValue(row.include_edit);
  const group = String(row.group_label_edit ?? "").trim();

  if (include === "FALSE") {
    return {
      type: "excluded",
      key: "__excluded__",
      label: "Excluded"
    };
  }

  if (include === "TRUE" && group !== "") {
    return {
      type: "group",
      key: `group:${group}`,
      label: group
    };
  }

  return {
    type: "unassigned",
    key: "__unassigned__",
    label: "Unassigned"
  };
}

function getDecisionGroupSummary() {
  const formalGroupCounts = new Map(
    [...knownGroups].map((group) => [group, 0])
  );
  let unassignedCount = 0;
  let excludedCount = 0;

  currentRows.forEach((row) => {
    const classification = classifyDecisionRow(row);

    if (classification.type === "unassigned") {
      unassignedCount += 1;
      return;
    }

    if (classification.type === "excluded") {
      excludedCount += 1;
      return;
    }

    if (!formalGroupCounts.has(classification.label)) {
      formalGroupCounts.set(classification.label, 0);
      knownGroups.add(classification.label);
    }

    formalGroupCounts.set(
      classification.label,
      (formalGroupCounts.get(classification.label) ?? 0) + 1
    );
  });

  const formalGroups = [...formalGroupCounts.entries()]
    .map(([label, count]) => ({
      type: "group",
      key: `group:${label}`,
      label,
      count
    }))
    .sort((a, b) =>
      a.label.localeCompare(b.label, undefined, {
        sensitivity: "base"
      })
    );

  return {
    total: currentRows.length,
    items: [
      {
        type: "unassigned",
        key: "__unassigned__",
        label: "Unassigned",
        count: unassignedCount
      },
      ...formalGroups,
      {
        type: "excluded",
        key: "__excluded__",
        label: "Excluded",
        count: excludedCount
      }
    ]
  };
}

function getFilterDisplayLabel(filterKey) {
  if (filterKey === "__all__") return "All samples";
  if (filterKey === "__unassigned__") return "Unassigned";
  if (filterKey === "__excluded__") return "Excluded";
  if (filterKey.startsWith("group:")) return filterKey.slice("group:".length);
  return "All samples";
}

function getVisibleDecisionRows() {
  return currentRows
    .map((row, rowIndex) => ({
      row,
      rowIndex,
      classification: classifyDecisionRow(row)
    }))
    .filter((entry) => {
      if (activeGroupFilter === "__all__") return true;
      return entry.classification.key === activeGroupFilter;
    });
}

function renderGroupList() {
  const summary = getDecisionGroupSummary();
  const allItem = {
    type: "all",
    key: "__all__",
    label: "All samples",
    count: summary.total
  };
  const items = [allItem, ...summary.items];
  const availableKeys = new Set(items.map((item) => item.key));

  if (!availableKeys.has(activeGroupFilter)) {
    activeGroupFilter = "__all__";
  }

  byId("groupTotalCount").textContent = formatInteger(summary.total);

  byId("groupList").innerHTML = items
    .map((item) => {
      const iconClass =
        item.type === "all"
          ? "all"
          : item.type === "unassigned"
            ? "unassigned"
            : item.type === "excluded"
              ? "excluded"
              : "group";

      const isActive = item.key === activeGroupFilter;
      const groupControls =
        item.type === "group"
          ? `
              <div class="group-item-actions">
                <button
                  class="group-action-button"
                  type="button"
                  data-rename-group="${encodeURIComponent(item.label)}"
                  aria-label="Rename ${escapeHtml(item.label)}"
                  title="Rename group"
                >
                  Rename
                </button>
                <button
                  class="group-action-button danger"
                  type="button"
                  data-delete-group="${encodeURIComponent(item.label)}"
                  aria-label="Remove ${escapeHtml(item.label)}"
                  title="Remove group"
                >
                  Remove
                </button>
              </div>
            `
          : "";

      return `
        <div
          class="group-list-row ${isActive ? "is-active" : ""}"
          data-group-kind="${escapeHtml(item.type)}"
        >
          <button
            class="group-list-main"
            type="button"
            data-group-filter="${encodeURIComponent(item.key)}"
            aria-pressed="${isActive ? "true" : "false"}"
          >
            <span class="group-list-icon ${iconClass}" aria-hidden="true"></span>
            <span class="group-list-label">${escapeHtml(item.label)}</span>
            <span class="group-list-count">${formatInteger(item.count)}</span>
          </button>
          ${groupControls}
        </div>
      `;
    })
    .join("");

  renderBatchGroupOptions();
}

function renderFilteredTable() {
  const visibleEntries = getVisibleDecisionRows();
  const total = currentRows.length;
  const visible = visibleEntries.length;
  const label = getFilterDisplayLabel(activeGroupFilter);

  byId("sampleTableTitle").textContent =
    activeGroupFilter === "__all__"
      ? "All samples"
      : `${label} samples`;

  byId("sampleTableCount").textContent =
    activeGroupFilter === "__all__"
      ? `${formatInteger(total)} ${total === 1 ? "sample" : "samples"}`
      : `${formatInteger(visible)} of ${formatInteger(total)} samples`;

  renderTable(visibleEntries);
}

function getSelectedRows() {
  return currentRows.filter((row) =>
    selectedSampleIds.has(String(row.sample_id ?? "").trim())
  );
}

function renderBatchGroupOptions(preferredValue = null) {
  const select = byId("batchGroupSelect");
  const currentValue = preferredValue ?? select.value;

  const groups = [...knownGroups].sort((a, b) =>
    a.localeCompare(b, undefined, {
      sensitivity: "base"
    })
  );

  select.innerHTML = [
    '<option value="">Move to group…</option>',
    ...groups.map(
      (group) =>
        `<option value="${escapeHtml(group)}">${escapeHtml(group)}</option>`
    )
  ].join("");

  const resolved = groups.includes(currentValue)
    ? currentValue
    : "";

  select.value = resolved;
  updateBatchMoveState();
}

function updateBatchMoveState() {
  byId("batchMoveButton").disabled =
    selectedSampleIds.size === 0 ||
    normalizeGroupName(byId("batchGroupSelect").value) === "";
}

function renderSelectionState() {
  const selectedCount = selectedSampleIds.size;
  const toolbar = byId("batchToolbar");

  toolbar.hidden = selectedCount === 0;
  byId("selectedCount").textContent =
    `${formatInteger(selectedCount)} ` +
    `${selectedCount === 1 ? "sample" : "samples"} selected`;

  updateBatchMoveState();
  syncSelectionCheckboxes();
}

function syncSelectionCheckboxes() {
  const visibleEntries = getVisibleDecisionRows();
  const visibleIds = visibleEntries.map(({ row }) =>
    String(row.sample_id ?? "").trim()
  );

  const selectedVisibleCount = visibleIds.filter((sampleId) =>
    selectedSampleIds.has(sampleId)
  ).length;

  const selectAll = byId("tableContainer").querySelector(
    "[data-select-all-visible]"
  );

  if (selectAll) {
    selectAll.checked =
      visibleIds.length > 0 &&
      selectedVisibleCount === visibleIds.length;
    selectAll.indeterminate =
      selectedVisibleCount > 0 &&
      selectedVisibleCount < visibleIds.length;
  }

  byId("tableContainer")
    .querySelectorAll("[data-select-sample]")
    .forEach((checkbox) => {
      const sampleId = decodeURIComponent(
        checkbox.dataset.selectSample
      );
      checkbox.checked = selectedSampleIds.has(sampleId);
    });
}

function setSelectionRange(anchorSampleId, targetSampleId, selected) {
  const visibleIds = getVisibleDecisionRows().map(({ row }) =>
    String(row.sample_id ?? "").trim()
  );

  const anchorIndex = visibleIds.indexOf(anchorSampleId);
  const targetIndex = visibleIds.indexOf(targetSampleId);

  if (anchorIndex === -1 || targetIndex === -1) {
    setSampleSelection(targetSampleId, selected);
    return;
  }

  const start = Math.min(anchorIndex, targetIndex);
  const end = Math.max(anchorIndex, targetIndex);

  visibleIds.slice(start, end + 1).forEach((sampleId) => {
    if (selected) {
      selectedSampleIds.add(sampleId);
    } else {
      selectedSampleIds.delete(sampleId);
    }
  });

  renderSelectionState();
}

function setSampleSelection(sampleId, selected) {
  if (selected) {
    selectedSampleIds.add(sampleId);
  } else {
    selectedSampleIds.delete(sampleId);
  }

  renderSelectionState();
}

function setVisibleSelection(selected) {
  selectionAnchorSampleId = null;
  pendingShiftSelection = false;

  getVisibleDecisionRows().forEach(({ row }) => {
    const sampleId = String(row.sample_id ?? "").trim();

    if (selected) {
      selectedSampleIds.add(sampleId);
    } else {
      selectedSampleIds.delete(sampleId);
    }
  });

  renderSelectionState();
}

function clearSelection() {
  selectedSampleIds.clear();
  selectionAnchorSampleId = null;
  pendingShiftSelection = false;
  renderSelectionState();
}

function createGroup() {
  const input = window.prompt("New group name:");
  if (input === null) return;

  const validation = validateNewGroupName(input);

  if (!validation.ok) {
    showDecisionStatus(validation.message, "error");
    return;
  }

  knownGroups.add(validation.name);
  renderGroupList();
  renderFilteredTable();
  renderBatchGroupOptions(validation.name);
  showDecisionStatus(
    `Group "${validation.name}" created. Assign samples to persist it.`,
    "success"
  );
}

function renameGroup(oldName) {
  const input = window.prompt(
    `Rename group "${oldName}" to:`,
    oldName
  );

  if (input === null) return;

  const validation = validateNewGroupName(input, oldName);

  if (!validation.ok) {
    showDecisionStatus(validation.message, "error");
    return;
  }

  const newName = validation.name;

  if (oldName === newName) return;

  currentRows.forEach((row) => {
    if (
      normalizeValue(row.include_edit) === "TRUE" &&
      normalizeGroupName(row.group_label_edit) === oldName
    ) {
      row.group_label_edit = newName;
    }
  });

  const previousRole = normalizeCaseControl(groupRoleMap[oldName]);
  delete groupRoleMap[oldName];

  if (previousRole) {
    groupRoleMap[newName] = previousRole;
  }

  knownGroups.delete(oldName);
  knownGroups.add(newName);

  if (activeGroupFilter === `group:${oldName}`) {
    activeGroupFilter = `group:${newName}`;
  }

  reconcileGroupRoleMap();
  renderDecisionWorkspace();
  markDecisionChanged();

  showDecisionStatus(
    `Group "${oldName}" renamed to "${newName}". ` +
    "Case/control mapping was preserved.",
    "success"
  );
}

function deleteGroup(groupName) {
  const members = currentRows.filter(
    (row) =>
      normalizeValue(row.include_edit) === "TRUE" &&
      normalizeGroupName(row.group_label_edit) === groupName
  );

  const message =
    members.length === 0
      ? `Remove empty group "${groupName}"?`
      : `Remove group "${groupName}" and move its ${members.length} ` +
        `${members.length === 1 ? "sample" : "samples"} to Unassigned?`;

  if (!window.confirm(message)) return;

  members.forEach((row) => {
    row.include_edit = "";
    row.group_label_edit = "";
    row.case_control_edit = "";
  });

  knownGroups.delete(groupName);
  delete groupRoleMap[groupName];

  if (activeGroupFilter === `group:${groupName}`) {
    activeGroupFilter = "__unassigned__";
  }

  reconcileGroupRoleMap();
  renderDecisionWorkspace();
  markDecisionChanged();

  showDecisionStatus(
    members.length === 0
      ? `Empty group "${groupName}" removed.`
      : `Group "${groupName}" removed. Its samples are now Unassigned.`,
    "success"
  );
}

function moveSelectedToGroup() {
  const group = normalizeGroupName(byId("batchGroupSelect").value);

  if (selectedSampleIds.size === 0 || group === "") return;

  const canonicalGroup = findKnownGroupByName(group) ?? group;
  knownGroups.add(canonicalGroup);

  getSelectedRows().forEach((row) => {
    row.include_edit = "TRUE";
    row.group_label_edit = canonicalGroup;
    row.reason_exclude_edit = "";
  });

  reconcileGroupRoleMap();
  clearSelection();
  renderDecisionWorkspace();
  markDecisionChanged();

  showDecisionStatus(
    `Selected samples moved to "${canonicalGroup}" and marked Included.`,
    "success"
  );
}

function excludeSelected() {
  if (selectedSampleIds.size === 0) return;

  getSelectedRows().forEach((row) => {
    row.include_edit = "FALSE";
    row.group_label_edit = "";
    row.case_control_edit = "";
  });

  reconcileGroupRoleMap();
  clearSelection();
  renderDecisionWorkspace();
  markDecisionChanged();

  showDecisionStatus(
    "Selected samples moved to Excluded.",
    "success"
  );
}

function unassignSelected() {
  if (selectedSampleIds.size === 0) return;

  getSelectedRows().forEach((row) => {
    row.include_edit = "";
    row.group_label_edit = "";
    row.case_control_edit = "";
    row.reason_exclude_edit = "";
  });

  reconcileGroupRoleMap();
  clearSelection();
  renderDecisionWorkspace();
  markDecisionChanged();

  showDecisionStatus(
    "Selected samples moved to Unassigned.",
    "success"
  );
}

function renderDecisionWorkspace() {
  renderGroupRoleMapping();
  renderGroupList();
  renderFilteredTable();
  renderSelectionState();
}

function getIncludedGroups() {
  const counts = new Map();

  currentRows.forEach((row) => {
    const include = normalizeValue(row.include_edit);
    const group = String(row.group_label_edit ?? "").trim();

    if (include === "TRUE" && group !== "") {
      counts.set(group, (counts.get(group) ?? 0) + 1);
    }
  });

  return [...counts.entries()]
    .map(([group, count]) => ({ group, count }))
    .sort((a, b) => a.group.localeCompare(b.group));
}

function initializeGroupRoleMapFromRows() {
  groupRoleMap = {};

  getIncludedGroups().forEach(({ group }) => {
    const roles = [
      ...new Set(
        currentRows
          .filter(
            (row) =>
              normalizeValue(row.include_edit) === "TRUE" &&
              String(row.group_label_edit ?? "").trim() === group
          )
          .map((row) => normalizeCaseControl(row.case_control_edit))
          .filter(Boolean)
      )
    ];

    groupRoleMap[group] = roles.length === 1 ? roles[0] : "";
  });

  applyGroupRolesToRows();
}

function reconcileGroupRoleMap() {
  const groups = getIncludedGroups().map((item) => item.group);
  const nextMap = {};

  groups.forEach((group) => {
    nextMap[group] = normalizeCaseControl(groupRoleMap[group]);
  });

  groupRoleMap = nextMap;
  applyGroupRolesToRows();
}

function applyGroupRolesToRows() {
  currentRows.forEach((row) => {
    const include = normalizeValue(row.include_edit);
    const group = String(row.group_label_edit ?? "").trim();

    if (include === "TRUE" && group !== "") {
      row.case_control_edit = normalizeCaseControl(groupRoleMap[group]);
    } else {
      row.case_control_edit = "";
    }
  });
}

function validateGroupRoles() {
  const groups = getIncludedGroups();

  if (groups.length !== 2) {
    return {
      ok: false,
      message:
        `V1 two-group mode requires exactly 2 included groups. Current: ${groups.length}.`
    };
  }

  const missingGroups = groups
    .map((item) => item.group)
    .filter((group) => normalizeCaseControl(groupRoleMap[group]) === "");

  if (missingGroups.length > 0) {
    return {
      ok: false,
      message: `Assign case/control to: ${missingGroups.join(", ")}`
    };
  }

  const roles = groups.map((item) =>
    normalizeCaseControl(groupRoleMap[item.group])
  );

  if (!roles.includes("case") || !roles.includes("control")) {
    return {
      ok: false,
      message: "Assign one group as case and the other as control."
    };
  }

  return {
    ok: true,
    message: "Case/control mapping is ready for V1."
  };
}

function renderGroupRoleMapping() {
  const groups = getIncludedGroups();
  byId("groupRoleBox").hidden = false;

  if (groups.length === 0) {
    byId("groupRoleRows").innerHTML = "<p>No included groups yet.</p>";
    byId("groupRoleStatus").innerHTML =
      '<span class="inline-warn">Add included samples and group labels first.</span>';
    return;
  }

  byId("groupRoleRows").innerHTML = groups
    .map(({ group, count }) => {
      const role = normalizeCaseControl(groupRoleMap[group]);

      return `
        <div class="group-role-row">
          <div class="group-name">${escapeHtml(group)}</div>
          <div>${count} samples</div>
          <select data-group-role="${encodeURIComponent(group)}">
            <option value="" ${role === "" ? "selected" : ""}>Select role</option>
            <option value="case" ${role === "case" ? "selected" : ""}>Case</option>
            <option value="control" ${role === "control" ? "selected" : ""}>Control</option>
          </select>
        </div>
      `;
    })
    .join("");

  const validation = validateGroupRoles();
  byId("groupRoleStatus").innerHTML = validation.ok
    ? `<span class="inline-ok">${escapeHtml(validation.message)}</span>`
    : `<span class="inline-warn">${escapeHtml(validation.message)}</span>`;
}

function markDecisionChanged() {
  isDirty = true;
  byId("validationBox").hidden = true;
  byId("validationBox").textContent = "";
  byId("decisionReadyCard").hidden = true;

  appState.decisionReady = false;
  appState.validationSummary = null;

  lockNavigationFrom("v1");
  resetV1State();
}

async function loadProject() {
  const gse = byId("decisionGse").value.trim();
  const out = byId("out").value.trim();

  resetDecisionState();
  showDecisionStatus("Loading decision candidates…", "running");
  byId("loadProjectButton").disabled = true;

  const data = await apiPost("/api/project/load", { gse, out });

  byId("loadProjectButton").disabled = false;

  if (data.status !== "ok") {
    renderApiError("Unable to load decision candidates", data, byId("decisionStatus"));
    return;
  }

  byId("summary").hidden = false;
  byId("summary").innerHTML = `
    <strong>GSE:</strong> ${escapeHtml(data.gse)}<br />
    <strong>Samples:</strong> ${formatInteger(data.n_samples)}<br />
    <strong>Columns:</strong> ${formatInteger(data.columns.length)}
  `;

  currentRows = data.rows.map((row) => ({
    ...row,
    include_edit: normalizeValue(row.include_existing),
    group_label_edit:
      row.group_label_existing === null ||
      row.group_label_existing === undefined ||
      String(row.group_label_existing).trim().toUpperCase() === "NA"
        ? ""
        : String(row.group_label_existing).trim(),
    case_control_edit: normalizeCaseControl(row.case_control_existing),
    reason_exclude_edit:
      row.reason_exclude_existing === null ||
      row.reason_exclude_existing === undefined ||
      String(row.reason_exclude_existing).trim().toUpperCase() === "NA"
        ? ""
        : String(row.reason_exclude_existing)
  }));

  loadedInfo = data.loaded;
  isDirty = false;
  selectedSampleIds = new Set();

  initializeKnownGroupsFromRows();
  initializeGroupRoleMapFromRows();
  renderLoadedInfo();
  renderDecisionWorkspace();
  byId("decisionWorkspace").hidden = false;
  byId("createGroupButton").disabled = false;
  setDecisionControlsEnabled(true);
  showDecisionStatus("Decision candidates loaded.", "success");
}

function commitGroupLabel(rowIndex, newValue) {
  const row = currentRows[rowIndex];
  const group = normalizeGroupName(newValue);

  if (group === "") {
    row.group_label_edit = "";
    row.include_edit = "";
    row.case_control_edit = "";

    reconcileGroupRoleMap();
    renderDecisionWorkspace();
    markDecisionChanged();
    return;
  }

  const existing = findKnownGroupByName(group);
  const canonicalGroup = existing ?? group;

  if (!existing) {
    const validation = validateNewGroupName(group);

    if (!validation.ok) {
      showDecisionStatus(validation.message, "error");
      renderFilteredTable();
      return;
    }
  }

  row.group_label_edit = canonicalGroup;
  row.include_edit = "TRUE";
  row.reason_exclude_edit = "";
  knownGroups.add(canonicalGroup);

  reconcileGroupRoleMap();
  renderDecisionWorkspace();
  markDecisionChanged();

  showDecisionStatus(
    `Sample moved to "${canonicalGroup}" and marked Included.`,
    "success"
  );
}


function updateGroupRole(group, newValue) {
  groupRoleMap[group] = normalizeCaseControl(newValue);
  applyGroupRolesToRows();
  renderGroupRoleMapping();
  markDecisionChanged();
}

async function saveDecision() {
  if (!ensureLoadedDatasetMatch()) return;

  applyGroupRolesToRows();
  showDecisionStatus("Saving decision table…", "running");

  const data = await apiPost("/api/decision/save", {
    gse: byId("decisionGse").value.trim(),
    out: byId("out").value.trim(),
    rows: currentRows,
    datasetSignature: loadedInfo.datasetSignature
  });

  if (data.status !== "ok") {
    renderApiError("Save failed", data, byId("decisionStatus"));
    return;
  }

  isDirty = false;
  showDecisionStatus("Decision table saved.", "success");
}

async function exportAndMerge() {
  if (!ensureLoadedDatasetMatch()) return;

  reconcileGroupRoleMap();
  renderDecisionWorkspace();

  const unassignedRows = currentRows.filter(
    (row) => classifyDecisionRow(row).type === "unassigned"
  );

  if (unassignedRows.length > 0) {
    showDecisionStatus(
      `${unassignedRows.length} samples are still Unassigned. ` +
      "Move each sample to a group or Excluded before Export + Merge.",
      "error"
    );
    return;
  }

  const roleValidation = validateGroupRoles();
  if (!roleValidation.ok) {
    showDecisionStatus(roleValidation.message, "error");
    return;
  }

  applyGroupRolesToRows();
  showDecisionStatus("Exporting and merging decision metadata…", "running");

  const data = await apiPost("/api/decision/export-and-merge", {
    gse: byId("decisionGse").value.trim(),
    out: byId("out").value.trim(),
    rows: currentRows,
    datasetSignature: loadedInfo.datasetSignature
  });

  if (data.status !== "ok") {
    renderApiError("Export and merge failed", data, byId("decisionStatus"));
    return;
  }

  isDirty = false;
  appState.decisionReady = false;
  appState.validationSummary = null;
  byId("decisionReadyCard").hidden = true;
  lockNavigationFrom("v1");
  resetV1State();

  showDecisionStatus(
    "Decision metadata exported and merged successfully. Run Validation next.",
    "success"
  );
}

function parseValidationSummary(summaryText) {
  const result = {};

  String(summaryText ?? "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .forEach((line) => {
      const [key, ...rest] = line.split("\t");
      if (!key) return;
      result[key] = rest.join("\t");
    });

  return result;
}

async function runValidation() {
  if (!ensureLoadedDatasetMatch()) return;

  showDecisionStatus("Running decision validation…", "running");
  byId("runValidationButton").disabled = true;

  const data = await apiPost("/api/decision/run-validation", {
    gse: byId("decisionGse").value.trim(),
    out: byId("out").value.trim()
  });

  byId("runValidationButton").disabled = false;

  if (data.status !== "ok") {
    appState.decisionReady = false;
    lockNavigationFrom("v1");
    renderApiError("Validation failed", data, byId("decisionStatus"));
    return;
  }

  const summary = parseValidationSummary(
    data.validation_summary_text
  );
  const validationStatus = String(
    summary.validation_status ?? ""
  ).trim().toUpperCase();

  if (validationStatus !== "OK") {
    appState.decisionReady = false;
    appState.validationSummary = summary;
    lockNavigationFrom("v1");

    byId("validationBox").hidden = false;
    byId("validationBox").textContent =
`Validation completed but did not return validation_status = OK.
Summary: ${data.validation_summary_path}
Log: ${data.validation_log_path}

${data.validation_log_text ?? "(No validation log text found.)"}`;

    showDecisionStatus(
      "Decision validation did not pass.",
      "error"
    );
    return;
  }

  appState.decisionReady = true;
  appState.validationSummary = summary;
  appState.stage = "decision_ready";

  byId("validationBox").hidden = false;
  byId("validationBox").textContent =
`Validation status: OK
Included samples: ${summary.n_included ?? "—"}
Included groups: ${summary.group_levels_included ?? "—"}
Case/control mapping: ${summary.group_case_control_mapping ?? "—"}

Summary: ${data.validation_summary_path}
Log: ${data.validation_log_path}`;

  byId("decisionReadyCard").hidden = false;

  unlockNavigation("v1");
  showDecisionStatus(
    "Decision validation passed. V1 Analysis is unlocked.",
    "success"
  );
  setStageLabel("Decision ready");
}

function continueToV1() {
  if (!appState.decisionReady) {
    showDecisionStatus(
      "Run Decision validation successfully before continuing to V1.",
      "error"
    );
    return;
  }

  showPanel("v1");
  setStageLabel("V1 Analysis");
}

function resetV1State() {
  appState.v1Result = null;

  byId("v1CompleteCard").hidden = true;
  hideV1Status();
  hideResultsStatus();

  byId("runV1Button").disabled = false;
  byId("v1PadjCutoff").disabled = false;
  byId("v1LfcCutoff").disabled = false;

  byId("rerunThresholdsButton").disabled = false;
  byId("resultPadjCutoff").disabled = false;
  byId("resultLfcCutoff").disabled = false;

  clearResultAssets();
}

function setV1Running(isRunning, runMode) {
  byId("runV1Button").disabled = isRunning;
  byId("v1PadjCutoff").disabled = isRunning;
  byId("v1LfcCutoff").disabled = isRunning;

  byId("rerunThresholdsButton").disabled = isRunning;
  byId("resultPadjCutoff").disabled = isRunning;
  byId("resultLfcCutoff").disabled = isRunning;

  if (isRunning) {
    setStageLabel(
      runMode === "full"
        ? "Running V1"
        : "Recalculating results"
    );
  }
}

function showV1Status(message, type = "default") {
  const box = byId("v1Status");
  box.hidden = false;
  box.className = "status-box";

  if (type === "running") box.classList.add("is-running");
  if (type === "error") box.classList.add("is-error");
  if (type === "success") box.classList.add("is-success");

  box.textContent = message;
}

function hideV1Status() {
  const box = byId("v1Status");
  box.hidden = true;
  box.className = "status-box";
  box.textContent = "";
}

function showResultsStatus(message, type = "default") {
  const box = byId("resultsStatus");
  box.hidden = false;
  box.className = "status-box";

  if (type === "running") box.classList.add("is-running");
  if (type === "error") box.classList.add("is-error");
  if (type === "success") box.classList.add("is-success");

  box.textContent = message;
}

function hideResultsStatus() {
  const box = byId("resultsStatus");
  box.hidden = true;
  box.className = "status-box";
  box.textContent = "";
}

function getV1FormValues(runMode) {
  const isFull = runMode === "full";

  return {
    padj: Number(
      byId(
        isFull
          ? "v1PadjCutoff"
          : "resultPadjCutoff"
      ).value
    ),
    lfc: Number(
      byId(
        isFull
          ? "v1LfcCutoff"
          : "resultLfcCutoff"
      ).value
    )
  };
}

async function runV1(runMode) {
  if (!appState.decisionReady) {
    const target =
      runMode === "full"
        ? byId("v1Status")
        : byId("resultsStatus");

    renderApiError(
      "V1 cannot start",
      {
        message:
          "Decision validation must pass before running V1.",
        error: {
          code: "DECISION_NOT_READY"
        }
      },
      target
    );
    return;
  }

  const { padj, lfc } = getV1FormValues(runMode);
  const validation = validateV1Parameters(padj, lfc);

  if (!validation.ok) {
    const target =
      runMode === "full"
        ? byId("v1Status")
        : byId("resultsStatus");

    target.hidden = false;
    target.className = "status-box is-error";
    target.textContent = validation.message;
    return;
  }

  appState.stage = "running_v1";
  setV1Running(true, runMode);

  if (runMode === "full") {
    byId("v1CompleteCard").hidden = true;
    showV1Status(
      "Running full V1…\nSanity check, QC overview, DEG, Volcano, and MA plot.",
      "running"
    );
  } else {
    showResultsStatus(
      "Recalculating DEG results…\nQC figures will be retained from the previous full run.",
      "running"
    );
  }

  const result = await apiPost("/api/v1/run", {
    gse: appState.gse,
    padj_cutoff: padj,
    lfc_cutoff: lfc,
    run_mode: runMode
  });

  setV1Running(false, runMode);

  if (!(result.ok === true && result.state === "completed")) {
    appState.stage =
      appState.v1Result
        ? "v1_completed"
        : "decision_ready";

    const target =
      runMode === "full"
        ? byId("v1Status")
        : byId("resultsStatus");

    renderApiError("V1 failed", result, target);
    setStageLabel(
      appState.v1Result
        ? "Results"
        : "V1 Analysis"
    );
    return;
  }

  appState.stage = "v1_completed";
  appState.v1Result = result.data;

  renderV1Complete(result.data);
  renderResults(result.data);
  unlockNavigation("results");

  if (runMode === "full") {
    showV1Status(
      "Full V1 completed successfully.",
      "success"
    );
    setStageLabel("V1 completed");
  } else {
    showResultsStatus(
      "DEG table, Volcano plot, and MA plot were recalculated. QC figures were retained.",
      "success"
    );
    setStageLabel("Results");
  }
}

function renderV1Complete(data) {
  const params = data.parameters ?? {};

  byId("v1CompleteGse").textContent = data.gse ?? "—";
  byId("v1CompletePadj").textContent =
    String(params.padj_cutoff ?? "—");
  byId("v1CompleteLfc").textContent =
    String(params.lfc_cutoff ?? "—");

  byId("v1CompleteCard").hidden = false;

  byId("v1PadjCutoff").value =
    String(params.padj_cutoff ?? 0.05);
  byId("v1LfcCutoff").value =
    String(params.lfc_cutoff ?? 1);
}

function continueToResults() {
  if (!appState.v1Result) {
    showV1Status(
      "Run V1 successfully before opening Results.",
      "error"
    );
    return;
  }

  showPanel("results");
  setStageLabel("Results");
}

function setImageAsset(imageId, linkId, url) {
  const image = byId(imageId);
  const link = byId(linkId);
  const resolved = String(url ?? "");

  image.src = resolved;
  image.hidden = resolved === "";
  link.href = resolved || "#";
  link.setAttribute(
    "aria-disabled",
    resolved === "" ? "true" : "false"
  );
}

function setResultLink(id, url) {
  const link = byId(id);
  const resolved = String(url ?? "");
  link.href = resolved || "#";
  link.setAttribute(
    "aria-disabled",
    resolved === "" ? "true" : "false"
  );
}

function clearResultAssets() {
  [
    ["pcaImage", "pcaOpenLink"],
    ["distanceHeatmapImage", "distanceHeatmapOpenLink"],
    ["expressionBoxplotImage", "expressionBoxplotOpenLink"],
    ["volcanoImage", "volcanoOpenLink"],
    ["maImage", "maOpenLink"]
  ].forEach(([imageId, linkId]) => {
    const image = byId(imageId);
    const link = byId(linkId);

    image.removeAttribute("src");
    image.hidden = true;
    link.href = "#";
    link.setAttribute("aria-disabled", "true");
  });

  [
    "degTableLink",
    "degSummaryLink",
    "qcManifestLink",
    "degManifestLink",
    "volcanoPointsLink",
    "maPointsLink"
  ].forEach((id) => {
    const link = byId(id);
    link.href = "#";
    link.setAttribute("aria-disabled", "true");
  });

  byId("resultThresholdSummary").textContent = "—";
}

function renderResults(data) {
  const figures = data.outputs?.figures ?? {};
  const results = data.outputs?.results ?? {};
  const params = data.parameters ?? {};
  const runMode = data.run_mode ?? "full";

  setImageAsset("pcaImage", "pcaOpenLink", figures.pca);
  setImageAsset(
    "distanceHeatmapImage",
    "distanceHeatmapOpenLink",
    figures.distance_heatmap
  );
  setImageAsset(
    "expressionBoxplotImage",
    "expressionBoxplotOpenLink",
    figures.expression_boxplot
  );
  setImageAsset(
    "volcanoImage",
    "volcanoOpenLink",
    figures.volcano
  );
  setImageAsset("maImage", "maOpenLink", figures.ma_plot);

  setResultLink("degTableLink", results.deg_table);
  setResultLink("degSummaryLink", results.deg_summary);
  setResultLink("qcManifestLink", results.qc_manifest);
  setResultLink("degManifestLink", results.deg_manifest);
  setResultLink("volcanoPointsLink", results.volcano_points);
  setResultLink("maPointsLink", results.ma_points);

  byId("resultPadjCutoff").value =
    String(params.padj_cutoff ?? 0.05);
  byId("resultLfcCutoff").value =
    String(params.lfc_cutoff ?? 1);

  byId("resultThresholdSummary").textContent =
    `padj ≤ ${params.padj_cutoff ?? "—"}; ` +
    `|log2FC| ≥ ${params.lfc_cutoff ?? "—"}`;

  byId("resultRunModeBadge").textContent =
    runMode === "thresholds_only"
      ? "Threshold rerun"
      : "Full run";
}

function getDecisionColumnLabel(column) {
  const labels = {
    sample_id: "Sample ID",
    title: "Title",
    source_name_ch1: "Source",
    characteristics: "Characteristics",
    __status__: "Status",
    group_label_edit: "Group",
    __qc__: "QC",
    __history__: "Existing state"
  };

  return labels[column] ?? column;
}

function getDecisionColumnClass(column) {
  const classes = {
    sample_id: "col-sample-id",
    title: "col-title",
    source_name_ch1: "col-source",
    characteristics: "col-characteristics",
    __status__: "col-status",
    group_label_edit: "col-group",
    __qc__: "col-qc",
    __history__: "col-history"
  };

  return classes[column] ?? "col-generic";
}

function normalizeDisplayValue(value) {
  const text = String(value ?? "").trim();
  return text === "" || text.toUpperCase() === "NA" ? "" : text;
}

function renderCharacteristics(value) {
  const text = normalizeDisplayValue(value);

  if (text === "") {
    return '<span class="cell-empty">—</span>';
  }

  return text
    .split(";")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => `<span>${escapeHtml(part)}</span>`)
    .join("");
}

function renderQcCell(row) {
  const flag = normalizeDisplayValue(row.qc_flag);
  const reason = normalizeDisplayValue(row.qc_reason);

  if (flag === "" && reason === "") {
    return '<span class="cell-empty">—</span>';
  }

  return `
    <div class="cell-stack compact">
      ${flag ? `<strong>${escapeHtml(flag)}</strong>` : ""}
      ${reason ? `<span>${escapeHtml(reason)}</span>` : ""}
    </div>
  `;
}

function renderExistingState(row) {
  const hasDecision =
    String(row.has_existing_decision ?? "").trim().toUpperCase() === "TRUE";
  const hasOverride =
    String(row.has_existing_override ?? "").trim().toUpperCase() === "TRUE";

  return `
    <div class="state-pair" aria-label="Existing decision and override state">
      <span class="mini-state ${hasDecision ? "is-present" : ""}">
        Decision ${hasDecision ? "✓" : "—"}
      </span>
      <span class="mini-state ${hasOverride ? "is-present" : ""}">
        Override ${hasOverride ? "✓" : "—"}
      </span>
    </div>
  `;
}

function renderTable(entries) {
  if (!entries || entries.length === 0) {
    const label = getFilterDisplayLabel(activeGroupFilter);

    byId("tableContainer").innerHTML = `
      <div class="empty-filter-state">
        <strong>No samples in ${escapeHtml(label)}.</strong>
        <span>Select another group from the left panel.</span>
      </div>
    `;

    renderSelectionState();
    return;
  }

  const firstRow = entries[0].row;

  const preferredColumns = [
    "sample_id",
    "title",
    "source_name_ch1",
    "characteristics",
    "__status__",
    "group_label_edit",
    "__qc__",
    "__history__"
  ];

  const columns = preferredColumns.filter((column) => {
    if (column.startsWith("__")) return true;
    return column in firstRow;
  });

  let html = `
    <table class="decision-table">
      <colgroup>
        <col class="selection-column" />
        ${columns
          .map(
            (column) =>
              `<col class="${escapeHtml(getDecisionColumnClass(column))}" />`
          )
          .join("")}
      </colgroup>
      <thead>
        <tr>
          <th class="selection-column">
            <input
              type="checkbox"
              data-select-all-visible
              aria-label="Select all visible samples"
              title="Select all visible samples"
            />
          </th>
  `;

  columns.forEach((column) => {
    const columnClass = getDecisionColumnClass(column);
    html += `
      <th class="${escapeHtml(columnClass)}">
        ${escapeHtml(getDecisionColumnLabel(column))}
      </th>
    `;
  });

  html += "</tr></thead><tbody>";

  entries.forEach(({ row, rowIndex }) => {
    const sampleId = String(row.sample_id ?? "").trim();
    const classification = classifyDecisionRow(row);
    const statusLabel =
      classification.type === "group"
        ? "Included"
        : classification.label;

    html += `
      <tr>
        <td class="selection-column">
          <input
            type="checkbox"
            data-select-sample="${encodeURIComponent(sampleId)}"
            aria-label="Select ${escapeHtml(sampleId)}"
            title="Click to select; Shift-click to select a range"
          />
        </td>
    `;

    columns.forEach((column) => {
      const columnClass = getDecisionColumnClass(column);

      if (column === "__status__") {
        html += `
          <td class="${escapeHtml(columnClass)}">
            <span class="decision-status-badge ${escapeHtml(classification.type)}">
              ${escapeHtml(statusLabel)}
            </span>
          </td>
        `;
        return;
      }

      if (column === "group_label_edit") {
        html += `
          <td class="${escapeHtml(columnClass)}">
            <input
              type="text"
              value="${escapeHtml(row[column] ?? "")}"
              data-group-row="${rowIndex}"
              placeholder="Unassigned"
              aria-label="Group for ${escapeHtml(sampleId)}"
            />
          </td>
        `;
        return;
      }

      if (column === "__qc__") {
        html += `
          <td class="${escapeHtml(columnClass)}">
            ${renderQcCell(row)}
          </td>
        `;
        return;
      }

      if (column === "__history__") {
        html += `
          <td class="${escapeHtml(columnClass)}">
            ${renderExistingState(row)}
          </td>
        `;
        return;
      }

      const rawValue = row[column] ?? "";
      const displayValue = normalizeDisplayValue(rawValue);

      if (column === "characteristics") {
        html += `
          <td
            class="${escapeHtml(columnClass)}"
            title="${escapeHtml(displayValue)}"
          >
            <div class="characteristics-list">
              ${renderCharacteristics(displayValue)}
            </div>
          </td>
        `;
        return;
      }

      html += `
        <td
          class="${escapeHtml(columnClass)}"
          title="${escapeHtml(displayValue)}"
        >
          ${displayValue === ""
            ? '<span class="cell-empty">—</span>'
            : escapeHtml(displayValue)}
        </td>
      `;
    });

    html += "</tr>";
  });

  html += "</tbody></table>";
  byId("tableContainer").innerHTML = html;
  renderSelectionState();
}
