# 🧬 DECISION_ARCHITECTURE — Decision Resolution Architecture

## 0. Purpose

This document defines the architecture of the Decision Layer in GenePipeline.

The Decision Layer is responsible for turning raw sample metadata, optional QC evidence,
and explicit user decisions into one canonical merged metadata file for downstream V1 analysis.

It exists to ensure that:

- downstream V1 modules consume one stable metadata source of truth
- metadata decision logic is explicit and reviewable
- manual override is traceable
- QC remains evidence only
- final sample inclusion is resolved before analysis

Stable file/schema definitions are governed by `CONTRACT.md`.
Behavioral rules and precedence are governed by `POLICY.md`.

---

## 1. Scope

This architecture applies to the V0 → Decision → V1 boundary.

Current supported scope:

- GEO microarray
- single GSE
- sample-level inclusion / grouping
- two-group downstream V1 mode

Out of scope as primary mode:

- multi-GSE merge
- RNA-seq
- paired / repeated measures
- complex contrast orchestration as default behavior

---

## 2. Core Principle

> Decision is resolved before analysis.

Decision Layer does not perform DEG analysis.
It resolves which samples are included, how they are grouped,
and what metadata state downstream analysis should consume.

---

## 3. Canonical Output

The canonical output of the Decision Layer is:

- `sample_metadata_merged.tsv`

This file is the downstream metadata single source of truth.

Downstream V1 modules must not consume:

- raw metadata directly
- decision table directly
- override table directly
- QC table directly

---

## 4. Decision Layer Inputs

### 4.1 Required

- `sample_metadata_raw.tsv`

### 4.2 Optional / user-facing decision inputs

- `sample_metadata_decision.tsv`
- `sample_metadata_override.tsv`

### 4.3 Optional evidence inputs

- `sample_qc_flags.tsv`

QC is evidence only.
It may be displayed and joined during decision preparation or resolution,
but it must not directly determine inclusion.

---

## 5. Decision Layer Stages

### 5.1 Metadata Parsing / Standardization

Raw metadata should preserve original fields while exposing standardized fields when available.

Examples:

- `title`
- `source_name_ch1`
- `characteristics_ch1.*`
- standardized semantic fields derived from raw metadata

This stage prepares metadata for decision, but does not resolve final inclusion.

---

### 5.2 Decision Candidate Construction

Purpose:

Build a UI-facing candidate table that combines:

- raw metadata
- optional QC evidence
- optional prior decision
- optional prior override

Outputs may include:

- `sample_metadata_decision_candidates.tsv`
- candidate summary tables for UI inspection

This stage is for display and editing support.
It does not write the final merged metadata.

---

### 5.3 Metadata Decision Authoring

At this stage, the user or Decision UI defines the primary metadata decision.

Typical fields:

- `sample_id`
- `include`
- `group_label`
- optional `case_control`
- optional exclusion reason

This is the primary rule-based decision layer.

---

### 5.4 Manual Override

Manual override is allowed only as an explicit exception mechanism.

Requirements:

- override must be explicit
- override reason must be recorded
- override should remain rare
- override must remain traceable

Override exists to handle justified exceptions, not to replace metadata-based decision as the main workflow.

---

### 5.5 Final Decision Resolution

This is the stage where final downstream-visible inclusion is resolved.

Inputs:

- raw metadata
- decision table
- optional override table
- optional QC evidence

Rules:

- precedence: manual override > metadata decision
- QC is joined as evidence only
- included samples must have valid `group_label`
- downstream-visible `include` must be normalized to `TRUE/FALSE`

The result of this stage is the canonical merged metadata.

---

### 5.6 Decision Output Validation

Decision outputs must be validated before entering V1.

Validation includes:

- raw metadata schema
- decision schema
- override schema
- QC schema
- merged metadata invariants
- expression ↔ metadata alignment
- downstream grouping requirements

This stage ensures that V1 receives a stable and analysis-ready metadata state.

---

## 6. Review Loop from V1

Decision Layer is resolved before analysis,
but it may be revised after V1 produces QC review evidence.

The review loop is:

```text
Decision Layer
    ↓
sample_metadata_merged.tsv
    ↓
V1 QC / downstream analysis
    ↓
review evidence
    ↓
user or UI revises decision / override
    ↓
Decision Layer rerun
```

Important:

- V1 QC is feedback evidence
- V1 QC is not the prerequisite for initial decision
- V1 QC must not directly modify inclusion

---

## 7. Downstream Contract

Decision Layer defines:

- WHAT samples enter analysis
- WHAT group labels downstream analysis uses

V1 defines:

- HOW included samples are analyzed

This separation is required to prevent:

- hidden filtering
- decision drift across modules
- QC silently modifying inclusion
- grouping logic being re-derived inside analysis scripts

---

## 8. Design Philosophy

### 8.1 Explicit over implicit
Decision must be visible in files, not hidden in module internals.

### 8.2 Rules before exceptions
Metadata-based decision is primary; override is secondary.

### 8.3 QC as evidence
QC supports review but does not directly control inclusion.

### 8.4 One canonical downstream metadata state
Only one merged metadata file should be visible downstream.

### 8.5 Reconstructability
A reviewer should be able to reconstruct why a sample was included or excluded.

---

## 9. Anti-patterns

The following are discouraged:

- direct manual editing of merged metadata without traceable upstream decision
- using QC flags to silently drop samples
- bypassing override reason recording
- re-deriving grouping logic inside V1 modules
- allowing V1 to mutate metadata state

---

## 10. Summary

GenePipeline separates:

- metadata semantics
- candidate construction for UI
- metadata decision authoring
- manual override
- final decision resolution
- validation before V1
- review feedback loop from V1

In short:

> Decision Layer defines the canonical metadata state for analysis,
> and V1 consumes that state without redefining it.
