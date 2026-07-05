# CONTRACT (Global) — Data & Interface Contract

## 0. Purpose

This document defines the global, stable contract for:

- File locations and naming conventions
- Tabular schemas for expression and sample metadata
- Merge rules between metadata and decision tables
- Minimum validations required for each module

Behavioral rules are defined in:
- POLICY.md

Decision logic is defined in:
- DECISION_ARCHITECTURE.md

---

# 1. Repository Layout

## 1.1 Canonical directories

- data_raw/<GSE>/
- data_processed/<GSE>/
- figures/<GSE>/
- results/<GSE>/
- V1_analysis/scripts/

---

## 1.2 File naming

### Expression
- expression_gene_log.tsv (canonical)

---

### Metadata

#### Raw metadata (V0 output)
- sample_metadata_raw.tsv   ← canonical

#### Deprecated alias (for backward compatibility)
- sample_metadata.tsv

#### Decision
- sample_metadata_decision.tsv

#### Final merged
- sample_metadata_merged.tsv

#### QC evidence
- sample_qc_flags.tsv

#### Optional
- sample_metadata_override.tsv

---

# 2. File Format Rules

- TSV
- UTF-8
- Missing = NA
- Header required

---

# 3. Data Contracts

## 3.1 Expression matrix (gene-level)

File:
- expression_gene_log.tsv

Requirements:

- first column: gene_id
- unique gene_id
- numeric values
- sample IDs match metadata
- all expression values must be finite
- NA / NaN / Inf / -Inf are not allowed

---

## 3.2 Sample metadata (raw)

File:
- sample_metadata_raw.tsv

Required:

- sample_id
- title
- source_name_ch1 (allow NA)

---

### Extended standardized fields (recommended)

- disease_status
- sample_type
- treatment_status
- hpv_status
- timepoint
- tissue_type

Rules:

- derived from raw metadata
- may be NA
- MUST NOT overwrite raw text

---

## 3.3 Decision table

File:
- sample_metadata_decision.tsv

Required:

- sample_id
- include
- group_label

Optional:

- case_control
- contrast_id
- group_order
- reason_exclude

---

### Invariants

- sample_id must exist in raw metadata
- include must not be all FALSE
- included samples must have group_label

---

## 3.4 QC table

File:
- sample_qc_flags.tsv

Required:

- sample_id
- qc_flag
- qc_reason

Optional:

- qc_metric

---

### Rules

- qc_flag MUST NOT directly determine inclusion
- QC is evidence only

---

## 3.5 Override table (optional)

File:
- sample_metadata_override.tsv

Fields:

- sample_id
- override_include
- override_group_label
- override_reason

---

### Rules

- override_reason REQUIRED
- used only in final inclusion resolution

---

## 3.6 Merged metadata

File:
- sample_metadata_merged.tsv

---

### Merge rule

raw metadata
LEFT JOIN decision
LEFT JOIN qc (optional)
LEFT JOIN override (optional)

---

### Required fields

- sample_id
- include (TRUE/FALSE)
- group_label

---

### Invariants

- no duplicate sample_id
- included samples must have valid group_label

---

## 3.7 Alignment

Expression samples must match metadata sample_id

Preferred:
- exact match

---

# 4. Validation Requirements

Each module MUST validate:

1. files exist
2. schema correct
3. sample alignment
4. inclusion valid
5. grouping valid

---

# 5. CLI Contract

Scripts SHOULD accept:

- --gse
- --expr
- --meta
- --out

---

# 6. Change Policy

Breaking changes must be documented.

---

# 7. References

- POLICY.md
- DECISION_ARCHITECTURE.md
