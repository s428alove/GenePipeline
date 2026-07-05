# 🧬 V1_ARCHITECTURE — Analysis Layer Architecture

## 0. Purpose

This document defines the architecture of the V1 analysis layer in GenePipeline.

V1_analysis is responsible for:

- consuming resolved, canonical analysis inputs
- validating downstream analysis readiness
- performing analysis-level QC
- running differential expression analysis
- producing analysis outputs, summaries, and traceable artifacts
- generating review evidence for decision refinement

V1 does not perform decision making.

Stable file/schema definitions are governed by `CONTRACT.md`.
Behavioral and precedence rules are governed by `POLICY.md`.
Decision logic is governed by `DECISION_ARCHITECTURE.md`.

---

## 1. Scope

Current supported scope:

- GEO microarray
- single GSE
- gene-level expression matrix
- two-group downstream differential expression
- limma-based DEG workflow

Out of scope as default V1 behavior:

- multi-GSE integration
- RNA-seq
- paired / repeated-measures models
- automatic multi-contrast orchestration as primary mode
- identifier remapping inside V1

---

## 2. Core Principle

> V1 consumes decisions — it does not create them.

V1 assumes that sample inclusion and grouping have already been resolved upstream.

V1 may produce evidence that supports later review,
but it must not redefine the metadata state by itself.

---

## 3. Position in Pipeline

```text
V0_data_ingest
    ↓
Decision Layer
    ↓
V1_analysis
```

Decision Layer defines the canonical metadata state.

V1 uses that state for analysis.

---

## 4. Canonical Inputs

V1 must consume the canonical downstream inputs:

- `data_processed/<GSE>/expression_gene_log.tsv`
- `data_processed/<GSE>/sample_metadata_merged.tsv`

These are the only formal metadata/expression inputs for downstream analysis.

V1 modules must not consume directly:

- `sample_metadata_raw.tsv`
- `sample_metadata_decision.tsv`
- `sample_metadata_override.tsv`
- `sample_qc_flags.tsv`

---

## 5. Input Assumptions

Before entering V1:

- sample inclusion has already been resolved
- `include` is valid and normalized
- included samples have non-empty `group_label`
- expression sample IDs align to metadata sample IDs
- if DEG is run, `case_control` is already defined when required by module logic

V1 is not responsible for inventing missing grouping semantics.

---

## 6. V1 Module Structure

### 6.1 Input Validation

Purpose:

Validate that canonical downstream inputs satisfy analysis requirements.

Responsibilities:

- file existence
- required columns
- sample alignment
- inclusion validity
- grouping constraints

Typical implementation:

- `_lib/validate_inputs.R`

Validation must fail fast.

---

### 6.2 Analysis-level QC

Purpose:

Evaluate the included cohort after decision resolution and before or alongside formal downstream modeling.

Typical outputs:

- PCA
- sample distance heatmap
- expression distribution plots
- sample count summaries
- QC gate summary

Typical implementation:

- `01_qc_dataset_overview.R`

This stage provides review evidence.
It does not modify inclusion.

---

### 6.3 Differential Expression

Purpose:

Run DEG analysis on the resolved included cohort.

Typical implementation:

- `02_run_differential_expression.R`

Current supported mode:

- exactly two groups among included samples
- explicit design logic
- limma-based modeling
- optional batch covariate if supported by module implementation

Expected traceability:

- design definition
- group labels used
- control/case mapping
- thresholds used for DEG summary

---

### 6.4 Interpretation (future)

Purpose:

Convert DEG outputs into human-readable result summaries.

Potential outputs:

- DEG summaries
- top hits summaries
- direction summaries
- reviewer-facing text reports

This stage should remain downstream of formal DEG results.

---

### 6.5 Enrichment (future)

Purpose:

Perform pathway / functional interpretation on DEG outputs.

Potential outputs:

- enrichment tables
- pathway summaries
- plots

This stage must not redefine metadata or DEG design.

---

## 7. QC Role in V1

QC in V1 is analysis evidence only.

V1 QC must not:

- modify `include`
- modify `group_label`
- directly exclude samples
- overwrite metadata fields
- bypass Decision Layer

If V1 QC reveals problems,
the correct action is to review and revise Decision Layer inputs,
then rerun Decision Layer and V1.

---

## 8. Feedback Loop to Decision Layer

V1 produces review evidence, not direct decision updates.

The feedback loop is:

```text
Decision Layer
    ↓
sample_metadata_merged.tsv
    ↓
V1 QC / V1 analysis
    ↓
review evidence
    ↓
user or UI revises decision / override
    ↓
Decision Layer rerun
    ↓
V1 rerun
```

This ensures that metadata state remains explicit and reconstructable.

---

## 9. Outputs

V1 outputs should be written under stable result / figure locations.

Typical output roots:

- `results/<GSE>/`
- `figures/<GSE>/`

Typical module outputs include:

### QC
- PCA figure
- distance heatmap
- expression distribution plots
- group count summary
- QC run log
- manifest

### DEG
- DEG table
- DEG summary
- manifest

### Future stages
- interpretation summaries
- enrichment outputs
- corresponding manifests and logs

---

## 10. Traceability Requirements

V1 should preserve traceability for:

- canonical input paths
- module arguments
- group definitions used
- design assumptions
- output locations
- run summaries
- manifests

The purpose is not only to generate outputs,
but to make downstream analysis reconstructable.

---

## 11. Non-responsibilities

V1 must not:

- perform metadata decision authoring
- resolve final inclusion
- directly merge raw / decision / override / QC tables
- reinterpret identifier mapping already fixed in V0
- silently filter samples outside explicit validated rules
- depend on hidden state outside canonical inputs

---

## 12. Relation to V0 and Decision Layer

### V0 guarantees
- gene-level expression output
- processed expression ready for downstream use
- raw metadata extraction
- preprocessing / engineering evidence upstream

### Decision Layer guarantees
- one canonical merged metadata state
- explicit inclusion / grouping resolution
- optional override traceability
- metadata state suitable for downstream analysis

### V1 guarantees
- validated downstream analysis
- QC evidence
- DEG outputs
- analysis traceability

---

## 13. Design Philosophy

### 13.1 Single source of truth
V1 uses one merged metadata file.

### 13.2 Analysis after decision
Decision comes first; analysis comes second.

### 13.3 QC as review evidence
QC informs review but does not directly mutate metadata state.

### 13.4 Explicit design
DEG must be tied to explicit grouping and design assumptions.

### 13.5 Modular growth
Interpretation and enrichment can be added without collapsing the decision / analysis boundary.

---

## 14. Anti-patterns

The following are discouraged:

- reading raw metadata directly inside DEG modules
- deriving grouping logic inside analysis scripts
- changing inclusion based on hidden QC logic
- letting V1 write back implicit metadata updates
- redoing upstream identifier mapping in V1

---

## 15. Summary

GenePipeline V1_analysis is the downstream analysis layer that:

- consumes canonical inputs
- validates analysis readiness
- performs QC and DEG
- produces traceable outputs
- emits review evidence without redefining metadata

In short:

> Decision Layer defines what enters analysis.
> V1 defines how the resolved cohort is analyzed.
