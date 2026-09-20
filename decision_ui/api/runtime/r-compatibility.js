const registry = require("./r-compatibility.json");
function compareVersions(a, b) {
  const x = a.split(".").map(Number), y = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
  return 0;
}
function compatibility(version, policy = registry, platform = process.platform) {
  const guidance = "Install a validated R 4.5.x (4.5.2 or 4.5.3) alongside your current R and retry. You do not need to remove newer R or set an Rscript path.";
  const base = { version, policy: policy.id, supported: false, allowed: false, bestEffort: false, guidance };
  if (!/^\d+\.\d+\.\d+$/.test(version || "") || platform !== policy.platform)
    return { ...base, status: "unsupported", reason: "This policy validates Windows R with a recognized release version only." };
  if (policy.incompatible[version])
    return { ...base, status: "incompatible", reason: policy.incompatible[version] };
  if (compareVersions(version, `${policy.supportedLine}.0`) < 0)
    return { ...base, status: "unsupported", reason: `R ${version} is older than the maintained R ${policy.supportedLine} line.` };
  if (policy.validated[version])
    return { ...base, status: "validated", supported: true, allowed: true, evidence: policy.validated[version] };
  return { ...base, status: "unvalidated", allowed: true, bestEffort: true,
    warning: `R ${version} is unvalidated, not supported/validated by GenePipeline. Best-effort execution is allowed. If setup or analysis fails: ${guidance}` };
}
module.exports = { compatibility, compareVersions, registry };
