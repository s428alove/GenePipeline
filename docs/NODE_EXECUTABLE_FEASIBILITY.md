# Windows executable feasibility — report only

Investigated 2026-09-11 against the repository and its installed Node v22.18.0. No executable was built; this is an architecture feasibility report, not a packaging proof.

## Conclusion

Feasible with low intrusion to the current Browser → Express → child_process/Rscript → local files architecture. The first deliverable should be an executable plus resource directories, rather than a promise of one completely self-contained file. R and its packages remain external/user-installed. The browser UI and statistical pipeline do not need rewriting.

Node SEA can distribute the Node runtime and an embedded CommonJS entry. For the installed v22.18.0, SEA is in active development; its embedded entry's `require` is not normally file-based, and `__dirname` refers to the executable directory. The official flow generates a blob, injects it into a matching Node binary, and optionally signs the Windows executable. Assets can be retrieved through `node:sea`. These details require an explicit build/runtime layout. [Node v22.18.0 SEA documentation](https://nodejs.org/download/release/v22.18.0/docs/api/single-executable-applications.html)

Two practical routes inferred from those capabilities and the code:

1. **Minimal SEA bootstrap with external resources:** use `module.createRequire()` anchored beside the executable to load the existing API and shipped production dependencies. Keeping `decision_ui/api/server.js` as an external module preserves its current `__dirname`. Because the server now exports `createApp`, a bootstrap can call it and listen on port 3001. This has very little source impact but ships JS/node_modules alongside the executable.
2. **Bundled server SEA:** bundle Express, cors, server and runtime modules into one CommonJS entry. Add a resource-root resolver based on the executable's location; the current `../..` calculation cannot simply be carried over. Verify dependency runtime lookups and licenses during bundling. No native addon was identified in the current manifests, but a successful bundle/build/run still needs proof.

A lower-risk alternative is a portable directory containing the official `node.exe`, production dependencies, existing scripts/assets, and a launcher invoking the shipped runtime. End users would not need their own Node/npm. It is a portable distribution, not a single app executable. The current phase implements neither route.

## Files and paths needing special treatment

| Resource | Proposed treatment |
| --- | --- |
| `decision_ui/api/server.js`, `runtime/*.js`, Express/cors and transitive dependencies | External modules loaded by SEA bootstrap, or bundled with runtime resolution verified. Root/API manifest duplication should be resolved before release builds. |
| `decision_ui/frontend/index.html`, `app.js`, `styles.css` | Ship together as real files for unchanged `express.static`; embedding requires extraction or explicit asset-serving routes. Exclude `_deprecated`. |
| `V0_data_ingest/`, `decision_layer/`, `V1_analysis/` including `_lib`, `R`, scripts and `_tools` | Preserve relative directory structure on disk. External R cannot directly execute a SEA asset; embedded R resources would need extraction to a versioned location. |
| `data_raw/`, `data_processed/`, `results/`, `figures/` | Writable external user workspace. Never bake generated data into the executable. Server currently uses repository-relative locations, and R runners use cwd-relative defaults. A future data root must be consistent across both. |
| `.Rprofile`, `.Renviron`, R library / future renv configuration | Future explicit environment contract; not implicitly assumed to be included in SEA. Discovery is separate from package readiness. |
| `start_pipeline.bat`, `.genepipeline_path` | Distribution launcher must locate the executable/resources, retain meaningful startup errors and browser launch behavior, and avoid requiring npm. |

Current frontend HTML references local JS/CSS. Figures and result links are served from generated external files. Application packaging does not eliminate those file dependencies.

## Main blockers and expected change size

- **Paths:** bundled code changes `__dirname` semantics. Separate resource root from writable data root before installing under Program Files. Small centralized Node resolver change; possibly moderate R runner/default-path changes, depending on the chosen data layout. Statistical algorithms stay intact.
- **Dependencies:** explicitly choose external production node_modules versus a verified bundle. Packaging cannot fix missing R packages; this machine currently lacks visible `optparse`.
- **R script execution:** preserve real files and existing `cwd` contracts. Exercise V1 `system2` script/argument quoting on paths with spaces and non-ASCII characters. Node's R invocation already uses argument arrays.
- **Release engineering:** pin Node/build tooling, build/inject on the target architecture, check signing/SmartScreen, update behavior and licenses, test with no system Node/npm installed. Blob generation and injection must use matching Node versions.
- **Existing runtime behavior:** synchronous analysis blocks HTTP, port 3001 is fixed, and browser opening uses a fixed launcher delay. These are release-hardening concerns rather than reasons to introduce Electron.

Estimated scope: SEA bootstrap plus external tree is a small bootstrap/build-script change; bundled SEA plus separated resource/data roots is a moderate portability change. A fully embedded, extracted, signed, updateable single-file distribution is a larger release project. No frontend redesign or analysis rewrite is justified.

## Suggested Phase 2 spike acceptance checks

Build an isolated Windows distribution, launch from a path containing spaces/non-ASCII characters on a clean machine with R installed but no Node/npm, confirm UI and health, discover/probe R, run an isolated real R job and write/read an output, then verify no-R failure. Add clean-machine full demo regression after package setup. Do not treat this report as evidence that a shipped SEA binary already passes those checks.
