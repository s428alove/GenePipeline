# Portability foundation — Phase 1

Review date: 2026-09-11. No analysis algorithms or frontend files changed.

## Audit and boundaries

- Actual entry: `decision_ui/api/server.js`; frontend: `decision_ui/frontend/`.
- Launcher and README incorrectly referenced a nonexistent root `server.js`.
- Launcher also had a machine-specific Desktop fallback. It now checks the actual entry beside the launcher, then a saved valid project root, then the existing folder picker.
- Root package.json had dependencies but no start script; API package.json pointed to nonexistent `index.js`. Both now have correct start/preflight/test scripts. Root `npm ci` / `npm start` is the documented workflow. The two existing dependency manifests/lockfiles are preserved; consolidation is outside this change.
- Server already resolved data from the repository root and frontend relative to the API directory. Those paths are preserved and tested from a different cwd.
- Previous server forced R 4.5.2 at a particular absolute path. Only its version is retained as a temporary development baseline in selection policy.
- V1 runner already defaults to `R.home("bin")` and accepts `--rscript`; server passes the same selected executable to it. The old absolute path in the runner is an error-message example, not its runtime default, and was left untouched.
- Existing UI displays API `message` / error code, so no UI change is needed.
- Reviewed README, launcher, both manifests, server, V0/Decision/V1 architecture, CONTRACT, POLICY, and relevant runner interfaces. Their analysis/data contracts remain unchanged.

## Discovery, selection, preflight

`decision_ui/api/runtime/r-discovery.js`:

1. Enumerate absolute PATH directories in order (Windows environment key is case-insensitive). Ignore empty/relative entries to avoid implicit cwd execution. Look for `Rscript.exe` on Windows, `Rscript` elsewhere.
2. On Windows also enumerate immediate installation subdirectories under ProgramW6432/ProgramFiles `R`, Program Files (x86) `R`, and LocalAppData `Programs/R`. Defaults include `C:\Program Files\R`. Inspect `bin`, `bin/x64`, `bin/i386`; never derive version from the directory name.
3. Deduplicate real executable paths, retaining all discovery sources. Root entries are sorted to make ordering deterministic.
4. Execute every candidate with an argument array, no shell: `Rscript --vanilla -e 'cat("GENEPIPELINE_R_VERSION=", as.character(getRversion()), "\n", sep="")'`. Require exit 0 and a valid version marker. Per-candidate timeout is 5 seconds, output capped at 64 KiB, windows hidden.
5. Return `detected`, `candidates`, `scanErrors`. Each candidate records `detected`, `executablePath`, `version`, `source`, `sources`, `executableStatus`, `error`. A file being detected does not mean it is usable. Failed execution, timeout, invalid version output, and directory scan errors remain inspectable.

`r-selection.js` independently chooses among usable candidates. Central policy `phase1-baseline-path-unambiguous`:

1. Prefer exact R 4.5.2, preserving the previous development baseline.
2. Otherwise choose the first usable PATH candidate, honoring existing environment order.
3. Otherwise use the only usable version (multiple launchers of that same version use discovery order).
4. With multiple other versions and no PATH candidate, fail with `R_SELECTION_AMBIGUOUS`. The message suggests installing the baseline alongside existing R installations, without requiring manual path configuration.
5. With no usable candidates, fail with `R_NOT_AVAILABLE` and an install/repair message.

These fallbacks are not compatibility approval. We deliberately do not implement “highest verified version” yet. A future selector can replace `selectR` without changing discovery; `preflightR` also accepts injected discovery/selection functions for isolated testing.

`r-preflight.js` composes discovery and selection. `npm run preflight:r` prints JSON and exits 0/1. `GET /api/preflight/r` returns the existing API envelope: success data includes the structured runtime; failure returns HTTP 503, `stage: r_preflight`, and diagnostic details. Health remains liveness-only.

The same preflight runs before V0, V1, project/load, export-and-merge, and run-validation routes, before file mutations. The selected executable is held per request and passed to every R invocation. Requests re-discover R so install/repair takes effect immediately. Discovery uses `--vanilla` for a clean version probe; actual analysis retains its existing R startup/profile behavior.

## Verification on this Windows machine

Node v22.18.0 / npm 10.9.3. Installed existing lockfile dependencies with `npm ci --ignore-scripts`; no dependency versions changed.

| Case | Result |
| --- | --- |
| A: real discovery | PASS: directory discovery found both `C:\Program Files\R\R-4.5.2\bin\Rscript.exe` and `bin\x64\Rscript.exe`; both usable; selected the first. No input version/path supplied. |
| B: real execution | PASS: an independent second execution of the selected executable returned `4.5.2`. |
| C: no R | PASS: injected empty PATH/installation roots, without altering/uninstalling system R; all five R-backed routes plus preflight endpoint returned 503 / `R_NOT_AVAILABLE`; health and homepage remained available. |
| D: startup | PASS: actual Node server entry launched from a different cwd on port 3001; health and the exact current HTML/JS/CSS were served. Request validation with available R still returned its normal 400 error. |
| Additional | PASS: multi-install selection, mismatched directory/version names, PATH deduplication, malformed version output, nonzero exit, real timeout, nonexistent executable. |

Final `npm test`: **8 passed, 0 failed, 1 skipped**. The skipped test exercises the real Decision runner against isolated temporary metadata (including spaces in its path); it checks prerequisites and runs automatically when packages are available. Tests that exercise the current machine expect an installed R; they are not all hermetic unit tests.

An attempted Decision execution returned `there is no package called 'optparse'`. A separate V1 `--dry_run` attempt exited 1 at the existing bootstrap check for missing `optparse`; no analysis steps ran. The current R process sees only `C:/Program Files/R/R-4.5.2/library` in `.libPaths()`. No R packages were installed or changed. Therefore **full V0 → Decision → V1 analysis regression is not claimed**. The native batch folder picker / browser auto-open were reviewed but not interactively exercised; the launcher's exact Node entry command was exercised by the startup test.

The host environment also emits `C.UTF-8` locale startup warnings. They did not prevent version discovery; locale normalization remains separate work.

## Remaining limitations / Phase 2

- Define and validate an R compatibility matrix, then select the highest verified version. 4.5.2 is inherited development history, not a new certification.
- Complete package environment setup and full demo analysis regression; introduce renv only in the planned package-management phase.
- Add registry/custom installation location discovery and, if needed, broader OS support. A custom R outside the searched roots and PATH is not found yet; users are not asked to type executable paths.
- Consider asynchronous discovery, bounded total scan time/cache invalidation, and handling installations disappearing between probe and analysis. Per-candidate timeout exists; discovery and existing analysis execution remain synchronous.
- Test clean Windows machines, non-ASCII/moved repository paths, multiple real R versions, and native launcher dialogs. V1's existing `system2` argument quoting needs a separate portability regression for script paths containing spaces; Node-to-R uses argument arrays already.
- See [executable feasibility](NODE_EXECUTABLE_FEASIBILITY.md) for resource/data-root work and packaging tests.

All changes remain local for review. No renv, Electron, executable packaging, algorithm changes, push, or merge.
