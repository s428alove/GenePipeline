# POLICY — Execution, Decision, Output & Identifier Policy (V0–V1)

This document defines execution behavior, decision resolution, validation expectations,
and output policies across the V0 → Decision → V1 workflow.

It governs:

- module behavior (validation, fail-fast, rerun/caching, logging)
- decision resolution behavior and precedence
- downstream metadata usage rules
- canonical outputs and identifier scope

The authoritative schema definitions remain in `CONTRACT.md`.

Related architecture documents:

- `V0_ARCHITECTURE.md`
- `DECISION_ARCHITECTURE.md`
- `V1_ARCHITECTURE.md`

---

# 1. Scope & Precedence

## 1.1 Scope

Applies to:

- `V0_data_ingest/`
- `decision_layer/`
- `V1_analysis/`
- any orchestrator running V0 / Decision / V1 modules

## 1.2 Precedence

- Schema / file paths / field definitions → `CONTRACT.md`
- Behavior / execution rules / precedence → `POLICY.md`
- Layer responsibilities → architecture documents

---

# 2. Single Source of Truth (Metadata)

## 2.1 Downstream metadata input

Downstream V1 modules MUST consume:

- `data_processed/<GSE>/sample_metadata_merged.tsv`

Downstream V1 modules MUST NOT consume directly:

- `sample_metadata_raw.tsv`
- `sample_metadata_decision.tsv`
- `sample_metadata_override.tsv`
- `sample_qc_flags.tsv`
- deprecated `sample_metadata.tsv`

---

## 2.2 Canonical downstream fields

Merged metadata MUST provide:

- `include` (`TRUE` / `FALSE`)
- `group_label` (non-empty for included samples)

When needed by downstream modules, merged metadata MAY also provide:

- `case_control`
- `contrast_id`
- `group_order`
- QC evidence columns
- traceable override-related columns

---

## 2.3 Integrity constraints

Pipeline MUST stop if:

- any `include == TRUE` sample has missing `group_label`
- `include` contains non-boolean downstream values
- sample_id mismatches the expression matrix
- duplicate sample_id appears in merged metadata

---

# 3. Fail-fast Validation Policy

## 3.1 Mandatory validation

Each executable module MUST validate the inputs it relies on.

Minimum validation includes:

1. files exist
2. schema is correct for required fields
3. sample_id alignment is valid
4. inclusion state is valid
5. grouping constraints are valid

---

## 3.2 Preflight summary

Modules SHOULD print or log:

- GSE
- input paths
- total samples
- included samples
- group levels among included samples
- output paths

---

## 3.3 Validation stages

### V0

V0 validates:

- raw ingest feasibility
- expression extraction feasibility
- annotation / mapping feasibility
- post-aggregation expression completeness
- canonical expression finiteness
- output writing feasibility

### Decision Layer

Decision Layer validates:

- raw metadata schema
- decision schema
- override schema when present
- QC schema when present
- merged metadata invariants
- expression ↔ metadata alignment when requested
- downstream grouping requirements when requested

### V1

V1 validates:

- canonical downstream input existence
- merged metadata invariants
- expression ↔ merged metadata alignment
- module-specific grouping requirements

---

# 4. Decision Resolution Policy

## 4.1 Overview

Decision Layer resolves the final downstream metadata state.

Decision is based on:

1. metadata-derived decision
2. manual override (explicit exception)
3. QC evidence (review support only)

Important:

- QC is evidence
- QC is not an independent decision authority
- final downstream inclusion is represented by one canonical field only: `include`

---

## 4.2 Precedence (STRICT)

Final downstream-visible decision MUST follow:

1. manual override
2. metadata decision

QC evidence may be joined, displayed, summarized, and reviewed,
but it MUST NOT silently override metadata decision or directly exclude samples.

---

## 4.3 Canonical inclusion rule

Downstream-visible inclusion MUST be represented only by:

- `include`

Forbidden downstream logic:

- using `include_metadata` as final truth
- using `include_qc` as final truth
- using `override_include` as final truth outside resolution
- recomputing final inclusion inside V1

---

## 4.4 QC role (CRITICAL)

QC is evidence only.

QC MUST NOT:

- directly determine final inclusion
- silently drop samples
- modify metadata fields in place
- bypass Decision Layer
- serve as a hidden exclusion path inside V1

QC MAY:

- appear in candidate tables
- appear in merged metadata as evidence columns
- support manual review
- motivate a later change in decision or override

---

## 4.5 Manual override policy

Manual override is allowed but:

- MUST be explicit
- MUST include reason
- MUST be traceable
- SHOULD be rare
- MUST NOT replace rule-based decision as the primary workflow

---

## 4.6 Failure conditions

Decision / downstream execution MUST stop if:

- `include` is invalid
- all samples are `FALSE`
- any included sample lacks `group_label`
- grouping requirements for the target module are not satisfied

---

# 5. Decision Layer Execution Policy

## 5.1 Recommended flow

Recommended Decision Layer flow:

1. build decision candidates
2. perform UI / manual editing
3. merge / resolve final metadata
4. validate decision outputs
5. pass canonical merged metadata downstream

---

## 5.2 Candidate stage

Candidate-building scripts:

- prepare UI-facing rows
- may join optional QC / prior decision / prior override
- MUST NOT write final inclusion state as merged metadata

---

## 5.3 Resolution stage

Resolution scripts:

- combine raw metadata
- combine decision table
- apply override when present
- join QC as evidence when present
- write canonical `sample_metadata_merged.tsv`

---

## 5.4 Validation stage

Validation scripts:

- verify decision-layer outputs before downstream analysis
- may check expression ↔ metadata alignment
- may check downstream mode requirements (for example two-group readiness)

---

# 6. Two-group vs Multi-contrast Policy

## 6.1 Two-group downstream modules

Two-group modules require:

- exactly 2 group levels among included samples

Otherwise modules MUST:

- stop
- instruct the user to refine Decision Layer inputs or specify a supported contrast workflow

---

## 6.2 Multi-contrast readiness

If multiple comparisons are intended, decision metadata SHOULD include:

- `contrast_id`

Modules that support multi-contrast MUST require explicit contrast selection
rather than inferring one silently.

---

# 7. QC Separation Policy

QC outputs MUST be stored separately from primary decision authoring inputs.

Canonical QC evidence file:

- `sample_qc_flags.tsv`

QC MUST NOT:

- modify raw metadata directly
- be consumed as final inclusion truth downstream
- be used as hidden filtering logic inside analysis modules

QC influence can occur only through explicit review and explicit decision-layer rerun.

---

# 8. V0 → Decision → V1 Separation

## 8.1 V0 guarantees

V0 is responsible for:

- gene-level expression output
- raw metadata extraction
- identifier mapping completion for downstream scope
- upstream engineering / QC evidence generation when applicable

---

## 8.2 Decision Layer guarantees

Decision Layer is responsible for:

- candidate construction
- metadata decision authoring
- optional override application
- final decision resolution
- canonical merged metadata generation
- validation before V1

---

## 8.3 V1 constraints

V1 MUST NOT:

- remap identifiers
- reinterpret probe / gene mapping already finalized in V0
- resolve final inclusion
- mutate metadata state
- directly consume raw / decision / override / QC tables as canonical inputs

---

# 9. Canonical Expression Output

## 9.1 Definition

Canonical downstream expression output:

- `data_processed/<GSE>/expression_gene_log.tsv`

Expected properties:

- gene-level
- sample columns aligned to metadata
- log-scale numeric values
- all canonical expression values are finite
- `NA`, `NaN`, `Inf`, and `-Inf` are not allowed

---

## 9.2 Post-aggregation Missing-value Policy

### 9.2.1 Scope

This policy applies after probe-to-gene aggregation and before writing the canonical:

- `data_processed/<GSE>/expression_gene_log.tsv`

It addresses non-finite gene-level expression values produced from raw missing values,
numeric conversion, annotation alignment, or probe aggregation.

### 9.2.2 Aggregation behavior

Probe-to-gene aggregation MUST:

- operate only on finite probe-level values when calculating a gene-level value
- return a non-finite result when no finite probe-level value is available for a gene/sample combination
- avoid silently replacing missing values with zero or another biological value

### 9.2.3 Baseline feature-filtering rule

For the baseline V0–V1 workflow:

- any gene containing one or more non-finite values after aggregation MUST be excluded from the canonical expression matrix
- this is feature-level filtering and MUST NOT be interpreted as sample exclusion
- retained gene values MUST NOT be altered by this filtering step
- group labels, case/control roles, or downstream outcomes MUST NOT be used to impute missing expression

The baseline workflow MUST NOT:

- replace missing expression with zero
- perform case/control-aware imputation
- silently retain incomplete genes in the canonical expression matrix
- defer repair of upstream expression missingness to V1

### 9.2.4 Engineering evidence

Every V0 run MUST write a post-aggregation missingness report:

- `data_processed/<GSE>/_engineering/gene_missingness.tsv`

The report MUST include, when applicable:

- `gene_id`
- `n_missing_samples`
- `missing_fraction`
- `action`
- `reason`

The V0 summary and run manifest SHOULD record:

- genes before missing-value filtering
- genes removed
- removed-gene fraction
- genes retained
- configured safety threshold
- missingness report path
- missing-value policy name

### 9.2.5 Safety threshold

The runner MUST apply an explicit, logged upper bound for the fraction of genes removed.

Baseline default:

- maximum removed-gene fraction: `0.05` (5%)

Behavior:

- if the removed fraction is less than or equal to the configured threshold, V0 may continue after recording the filtering evidence
- if the removed fraction exceeds the configured threshold, V0 MUST stop and require review of raw expression, annotation, or mapping
- changing the threshold MUST be explicit through a runner argument and MUST be recorded in the run summary or manifest

The threshold is an engineering guardrail, not a biological quality guarantee.

### 9.2.6 Final validation

After filtering, V0 MUST validate that:

- at least one gene remains
- all canonical expression values are finite
- gene identifiers remain non-empty and unique
- sample columns remain aligned to metadata

`validate_v0_minimal()` remains the final post-condition check.
Filtering handles an expected data condition; validation ensures that the canonical output contract is satisfied.

---

## 9.3 Identifier scope

Supported in V0–V1 baseline scope:

- gene-level identifiers supported by the current pipeline contract

Not supported as canonical downstream V1 scope:

- probe-level downstream analysis
- transcript-level downstream analysis
- ad hoc remapping inside V1

---

## 9.4 Out-of-scope datasets

Datasets failing required downstream gene-level mapping
MUST be excluded from V1 until V0 support is extended.

---

# 10. Partial Rerun / Caching (Recommended)

## 10.1 Manifest

Each module SHOULD produce:

- `results/<GSE>/manifest.json`

Recording, when feasible:

- inputs
- timestamps / hashes
- parameters
- outputs
- skip / rerun status

---

## 10.2 Skip behavior

Runners MAY skip unchanged stages.

If skipping is implemented, it MUST log the reason, for example:

- `SKIP: unchanged inputs/args`

## 10.3 V0 Annotation Mapping Cache

In the current baseline implementation, V0 MUST re-parse the selected annotation source on each run.

Probe-to-gene mapping cache reuse is disabled unless a future implementation provides
explicit cache invalidation based on annotation content, parser version, and mapping parameters.

Each run SHOULD record:

- selected annotation path
- resolved GPL
- parser / pipeline version when available
- mapped feature count
- resulting gene count

---

# 11. Logging Policy (Recommended)

Modules SHOULD output:

- console summary
- optional log files under stable result paths

Logs SHOULD include when feasible:

- R version
- parameters
- input paths
- output paths
- key counts / summaries
- error context when failing

---

# 12. Review Loop Policy

## 12.1 V1 QC as feedback evidence

V1 QC may produce evidence suggesting that the current cohort should be reviewed.

Examples:

- PCA outliers
- unexpected clustering
- suspicious expression distributions
- group imbalance discovery

This evidence MUST NOT directly rewrite metadata.

---

## 12.2 Correct review flow

Correct review flow:

1. V1 produces review evidence
2. user or UI revises decision / override inputs
3. Decision Layer reruns
4. merged metadata is regenerated
5. V1 reruns using the new canonical metadata state

---

# 13. Design Rationale

Pipeline policy enforces:

- single source of truth downstream
- explicit decision traceability
- separation of metadata, QC, and decision
- separation of engineering, resolution, and analysis
- reproducible reruns without hidden state

This avoids:

- hidden filtering
- inconsistent grouping
- irreproducible analysis
- decision drift across modules
- V1 silently mutating cohort definition
