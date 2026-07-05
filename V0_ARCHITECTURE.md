# 🧬 V0_ARCHITECTURE — Data Ingest & Engineering Layer Architecture

## 0. Purpose

This document defines the architecture of the V0 data ingest layer in GenePipeline.

V0_data_ingest is responsible for:

- reading raw GEO inputs
- extracting raw sample metadata
- generating upstream engineering evidence
- resolving platform annotation / mapping needed for expression standardization
- producing canonical processed outputs for downstream Decision Layer and V1 analysis

V0 is a data engineering layer.

It does not perform final sample inclusion decision making,
and it does not run downstream statistical modeling.

Stable file/schema definitions are governed by `CONTRACT.md`.
Behavioral rules are governed by `POLICY.md`.
Decision logic is governed by `DECISION_ARCHITECTURE.md`.
Analysis logic is governed by `V1_ARCHITECTURE.md`.

---

## 1. Scope

Current supported scope:

- GEO microarray
- single GSE
- series-matrix-driven ingest
- gene-level downstream expression output
- raw sample metadata extraction
- upstream engineering / QC evidence generation

Out of scope as primary V0 behavior:

- downstream sample inclusion decision
- DEG analysis
- enrichment
- interpretation
- multi-GSE meta-integration as default mode
- RNA-seq ingest as default mode

---

## 2. Core Principle

> V0 prepares analysis-ready data inputs, but does not decide the final cohort.

V0 exists to make raw GEO data usable, standardized, and traceable.

It should produce stable outputs that downstream layers can trust,
without embedding downstream decision or modeling logic inside the ingest layer.

---

## 3. Position in Pipeline

```text
Raw GEO inputs
    ↓
V0_data_ingest
    ↓
Decision Layer
    ↓
V1_analysis
```

V0 prepares the data state.

Decision Layer resolves the cohort state.

V1 analyzes the resolved cohort.

---

## 4. Canonical Outputs

V0 should produce stable processed outputs under:

- `data_processed/<GSE>/`

Canonical outputs include:

- `expression_gene_log.tsv`
- `sample_metadata_raw.tsv`

Optional / engineering outputs may include:

- upstream QC evidence
- preprocessing logs
- mapping traceability
- manifests / run summaries

These outputs become the formal upstream inputs to downstream layers.

---

## 5. Raw Inputs

Typical V0 inputs include:

- GEO Series Matrix
- platform annotation / GPL annotation files when needed
- raw metadata embedded in GEO-derived files

V0 may also consume configuration / runner arguments such as:

- `--gse`
- input/output paths
- platform-related options

---

## 6. V0 Responsibilities

### 6.1 GEO Read / Parse

Purpose:

Read dataset-level GEO inputs and extract:

- expression values
- sample IDs
- raw metadata
- platform hints / GPL identifiers

This stage should preserve raw information as faithfully as possible.

---

### 6.2 Raw Metadata Extraction

Purpose:

Write canonical raw metadata for downstream decision work.

Canonical output:

- `sample_metadata_raw.tsv`

Required minimum fields should follow `CONTRACT.md`, including:

- `sample_id`
- `title`
- `source_name_ch1`

Recommended standardized fields may also be derived when available,
but raw text should not be overwritten.

This stage prepares metadata for decision,
but does not resolve final inclusion.

---

### 6.3 Upstream Engineering / Pre-QC Evidence

Purpose:

Generate engineering evidence that helps identify potential raw-scale or preprocessing issues.

Examples may include:

- scale inspection
- log2-related evidence
- NA / summary metrics
- distribution diagnostics
- pre-processing comparison summaries

Important:

- this evidence supports review
- it does not directly define final inclusion
- it must remain separate from downstream canonical `include`

---

### 6.4 Platform Annotation / Mapping

Purpose:

Resolve annotation resources needed to move from platform-level identifiers
toward the downstream supported identifier space.

Typical responsibilities:

- detect or resolve GPL / platform annotation
- map platform entities to supported downstream gene identifiers
- keep mapping traceability

This stage is critical because `POLICY.md` states that V1 must not remap identifiers again.

---

### 6.5 Probe-to-Gene / Feature Aggregation

Purpose:

Transform upstream expression into the canonical downstream expression form.

Canonical output:

- `expression_gene_log.tsv`

Expected properties:

- gene-level matrix
- first column: `gene_id`
- numeric log-scale values
- sample IDs aligned to metadata

This is the V0 boundary for downstream expression standardization.

Probe-to-gene aggregation
→ Post-aggregation missingness assessment
→ Traceable gene filtering
→ Canonical expression output

---

### 6.6 Output Writing

Purpose:

Write canonical processed outputs and engineering artifacts under stable paths.

Typical locations:

- `data_processed/<GSE>/`
- optional engineering subfolders / logs

Outputs should be deterministic and reconstructable.

---

## 7. What V0 Guarantees

Before data enters Decision Layer, V0 guarantees:

- a canonical gene-level expression file exists
- a canonical raw metadata file exists
- identifier mapping required for downstream analysis is already completed
- upstream engineering evidence is available if generated
- sample IDs are available for downstream alignment

These guarantees are also reflected in `POLICY.md`,
which states that V0 completes identifier mapping and metadata alignment before V1.

---

## 8. What V0 Does NOT Do

V0 must not:

- define final `include`
- define final `group_label`
- apply manual override
- produce `sample_metadata_merged.tsv`
- run DEG
- reinterpret downstream grouping logic
- silently embed decision outcomes into engineering outputs

Those responsibilities belong downstream.

---

## 9. Relation to Decision Layer

Decision Layer consumes V0 outputs, especially:

- `sample_metadata_raw.tsv`
- optional upstream QC evidence
- canonical sample IDs aligned to expression

Decision Layer is responsible for:

- candidate construction
- metadata decision authoring
- manual override
- final decision resolution
- writing `sample_metadata_merged.tsv`

Therefore:

> V0 prepares raw metadata and expression for decision,
> but does not resolve the final cohort.

---

## 10. Relation to V1

V1 consumes canonical downstream inputs after Decision Layer has completed resolution.

V1 must consume:

- `expression_gene_log.tsv`
- `sample_metadata_merged.tsv`

V1 must not:

- re-read raw metadata as its primary input
- redo identifier mapping
- reinterpret probe-level structures

Therefore:

> V0 standardizes the data substrate,
> Decision defines the cohort,
> V1 performs the analysis.

---

## 11. Traceability Requirements

V0 should preserve traceability for:

- raw input provenance
- annotation source / mapping choices
- preprocessing / engineering evidence
- output paths
- run summaries
- manifests when available

The purpose is to make upstream processing reconstructable.

---

## 12. Design Philosophy

### 12.1 Engineering before decision
V0 prepares data but does not decide the cohort.

### 12.2 Canonical output first
Downstream layers should receive stable files, not ad hoc intermediate objects.

### 12.3 Preserve raw meaning
Raw metadata text should be retained while allowing standardized helper fields.

### 12.4 Separate evidence from decision
Upstream QC / engineering evidence may inform downstream review,
but should not silently become final inclusion logic.

### 12.5 One-way identifier normalization
Identifier mapping should be completed upstream and not redefined inside V1.

---

## 13. Anti-patterns

The following are discouraged:

- writing final inclusion decisions inside V0
- mixing metadata decision with preprocessing code
- letting raw engineering evidence directly become downstream `include`
- requiring V1 to repair identifier mapping
- bypassing canonical file outputs in favor of hidden intermediate state

---

## 14. Summary

GenePipeline V0_data_ingest is the upstream engineering layer that:

- reads raw GEO inputs
- extracts raw metadata
- generates engineering / pre-QC evidence
- resolves platform mapping
- writes canonical processed outputs for downstream use

In short:

> V0 defines the processed data substrate.
> Decision Layer defines the final cohort.
> V1 defines how the resolved cohort is analyzed.
