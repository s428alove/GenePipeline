// Previous server used R 4.5.2. This is a development baseline, not a compatibility matrix.
const DEFAULT_POLICY = Object.freeze({ id: "phase1-baseline-path-unambiguous", preferredVersion: "4.5.2" });

function selectR(discovery, policy = DEFAULT_POLICY) {
  const usable = discovery.candidates.filter((candidate) => candidate.executableStatus === "usable");
  const selected = usable.find((candidate) => candidate.version === policy.preferredVersion);
  if (selected) return { selected, policy: policy.id, reason: "development-baseline", error: null };
  const fromPath = usable.find((candidate) => candidate.sources.includes("PATH"));
  if (fromPath) return { selected: fromPath, policy: policy.id, reason: "first-usable-on-PATH", error: null };
  if (usable.length && new Set(usable.map((candidate) => candidate.version)).size === 1) {
    return { selected: usable[0], policy: policy.id, reason: "only-usable-version", error: null };
  }
  const ambiguous = usable.length > 0;
  return {
    selected: null, policy: policy.id, reason: null,
    error: {
      code: ambiguous ? "R_SELECTION_AMBIGUOUS" : "R_NOT_AVAILABLE",
      message: ambiguous
        ? "Multiple R versions are available, but this Phase 1 policy cannot safely choose one. Install the development baseline R 4.5.2 alongside them and retry. No manual Rscript path is needed."
        : "GenePipeline could not find a working R installation. Please install R (development baseline: 4.5.2), or repair your R installation, then retry. No manual Rscript path is needed."
    }
  };
}

module.exports = { selectR, DEFAULT_POLICY };
