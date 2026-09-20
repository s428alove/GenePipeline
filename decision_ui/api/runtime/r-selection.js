const { compatibility, compareVersions, registry: DEFAULT_POLICY } = require("./r-compatibility");

function selectR(discovery, policy = DEFAULT_POLICY) {
  const candidates = discovery.candidates.filter((c) => c.executableStatus === "usable")
    .map((c) => ({ ...c, compatibility: compatibility(c.version, policy) }));
  const byVersion = (a, b) => compareVersions(b.version, a.version) ||
    Number(b.sources.includes("PATH")) - Number(a.sources.includes("PATH"));
  const selected = candidates.filter((c) => c.compatibility.status === "validated").sort(byVersion)[0] ||
    candidates.filter((c) => c.compatibility.allowed).sort(byVersion)[0];
  if (selected) return { selected, compatibility: selected.compatibility, candidates,
    policy: policy.id, reason: selected.compatibility.status === "validated" ? "highest-validated" : "best-effort-unvalidated", error: null };
  const incompatible = candidates.some((c) => c.compatibility.status === "incompatible");
  return { selected: null, candidates, policy: policy.id, reason: null, error: {
    code: !candidates.length ? "R_NOT_AVAILABLE" : incompatible ? "R_INCOMPATIBLE" : "R_UNSUPPORTED",
    message: !candidates.length ? "GenePipeline could not find a working R installation. Please install R 4.5.2 or 4.5.3 and retry. No manual Rscript path is needed."
      : candidates.map((c) => "R " + c.version + ": " + c.compatibility.reason).join(" ") + " Install a validated R 4.5.2 or 4.5.3 alongside it and retry."
  } };
}
module.exports = { selectR, DEFAULT_POLICY };
