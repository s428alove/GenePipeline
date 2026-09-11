const { discoverR } = require("./r-discovery");
const { selectR } = require("./r-selection");

function preflightR({ discover = discoverR, select = selectR } = {}) {
  const discovery = discover();
  const selection = select(discovery);
  return { ok: Boolean(selection.selected), discovery, ...selection };
}

if (require.main === module) {
  const result = preflightR();
  console.log(JSON.stringify(result, null, 2));
  process.exitCode = result.ok ? 0 : 1;
}

module.exports = { preflightR };
