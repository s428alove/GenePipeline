# Decision Layer README

## Purpose

The Decision Layer formalizes sample-level inclusion and grouping into stable files that downstream V1 modules can consume.

This layer exists because:
- downstream V1 modules should read `sample_metadata_merged.tsv` as the single metadata source of truth
- QC is evidence only and must not directly modify inclusion
- manual override must be explicit and traceable
- decision logic should be separated from raw metadata and downstream analysis

These points follow the current policy and contract: `sample_metadata_merged.tsv` is the downstream metadata source, precedence is `manual override > metadata > QC`, and QC must not directly determine inclusion. fileciteturn0file0turn0file1

---

## Files

### `01_build_decision_candidates.R`
Builds a UI-facing candidate table from raw metadata and optional QC / existing decision / existing override files.

**Inputs**
- `sample_metadata_raw.tsv` (required)
- `sample_qc_flags.tsv` (optional)
- `sample_metadata_decision.tsv` (optional)
- `sample_metadata_override.tsv` (optional)

**Outputs**
- `sample_metadata_decision_candidates.tsv`
- `decision_candidates_summary.tsv`
- `decision_candidates_value_counts.tsv`

**Role**
- prepares a flat candidate table for Decision UI MVP
- gives the UI a consistent sample table to display
- does not resolve final inclusion
- does not write merged metadata

---

### `02_merge_decision_resolution.R`
Resolves final sample-level inclusion and grouping.

**Inputs**
- `sample_metadata_raw.tsv`
- `sample_metadata_decision.tsv`
- `sample_metadata_override.tsv` (optional)
- `sample_qc_flags.tsv` (optional)

**Outputs**
- `sample_metadata_merged.tsv`
- `decision_resolution_summary.tsv`

**Rules**
- precedence: `manual override > metadata decision`
- QC is joined as evidence only
- included samples must have `group_label`
- merged `include` is normalized to `TRUE/FALSE`

---

### `03_validate_decision_outputs.R`
Validates decision-layer outputs before downstream analysis.

**Validation scope**
- raw metadata schema
- decision schema
- override schema
- QC schema
- merged metadata invariants
- expression ↔ metadata alignment
- two-group requirement

**Outputs**
- `decision_validation_summary.tsv`
- `decision_validation_log.txt`

---

## Recommended flow

```text
sample_metadata_raw.tsv
    + optional QC
    + optional existing decision
    + optional existing override
→ 01_build_decision_candidates.R
→ Decision UI / manual editing
→ sample_metadata_decision.tsv
→ sample_metadata_override.tsv
→ 02_merge_decision_resolution.R
→ sample_metadata_merged.tsv
→ 03_validate_decision_outputs.R
→ V1 downstream modules
```

---

## Example commands

### 1) Build UI candidates

```bash
Rscript decision_layer/01_build_decision_candidates.R \
  --gse GSE10288 \
  --meta_raw data_processed/GSE10288/sample_metadata_raw.tsv \
  --qc data_processed/GSE10288/sample_qc_flags.tsv \
  --out data_processed/GSE10288
```

### 2) Resolve merged metadata

```bash
Rscript decision_layer/02_merge_decision_resolution.R \
  --gse GSE10288 \
  --meta_raw data_processed/GSE10288/sample_metadata_raw.tsv \
  --decision data_processed/GSE10288/sample_metadata_decision.tsv \
  --override data_processed/GSE10288/sample_metadata_override.tsv \
  --qc data_processed/GSE10288/sample_qc_flags.tsv \
  --out data_processed/GSE10288
```

### 3) Validate outputs

```bash
Rscript decision_layer/03_validate_decision_outputs.R \
  --gse GSE10288 \
  --expr data_processed/GSE10288/expression_gene_log.tsv \
  --meta_raw data_processed/GSE10288/sample_metadata_raw.tsv \
  --decision data_processed/GSE10288/sample_metadata_decision.tsv \
  --override data_processed/GSE10288/sample_metadata_override.tsv \
  --qc data_processed/GSE10288/sample_qc_flags.tsv \
  --meta data_processed/GSE10288/sample_metadata_merged.tsv \
  --out results/GSE10288/decision_validation
```

---

## What to do with old scripts

### `00_make_sample_metadata_merged.R`
Keep temporarily only as a migration reference.

Why:
- it merges raw + decision only
- it still carries older dataset-level gating assumptions
- it does not represent the new decision-layer split of candidate → resolve → validate
- it is now functionally superseded by `02_merge_decision_resolution.R`

Recommended action:
- mark as **deprecated**
- do not call it from new UI or V1 flow
- remove after the new flow is confirmed stable

The old script enforces raw + decision merging and dataset-level gate checks, but the new flow now separates decision resolution and validation more explicitly. fileciteturn2file0

### `01_make_merged_many.R`
Keep only if you still need a temporary batch wrapper during migration.

Why:
- it is only a loop wrapper around the old `00_make_sample_metadata_merged.R`
- once batch behavior is needed again, it should wrap the new `02_merge_decision_resolution.R` or a future decision pipeline runner instead

Recommended action:
- mark as **deprecated wrapper**
- do not extend it further
- replace later with a new batch runner if needed

The current old batch script simply iterates over multiple GSEs and calls the old merge script, so it is not aligned with the new split architecture. fileciteturn2file1

---

## MVP boundary

Decision Layer is not the same thing as V1 analysis.

This layer should:
- prepare candidate rows for UI
- formalize decision files
- resolve merged metadata
- validate the final metadata state

This layer should not:
- run DEG
- own limma logic
- replace V1 module validation
- let QC directly exclude samples

---

## Suggested next cleanup

1. Place these scripts under `decision_layer/`
2. Mark old `00_make_sample_metadata_merged.R` as deprecated
3. Mark old `01_make_merged_many.R` as deprecated
4. Point Decision UI MVP to `01_build_decision_candidates.R` and `02_merge_decision_resolution.R`
5. Point downstream V1 to `sample_metadata_merged.tsv`
