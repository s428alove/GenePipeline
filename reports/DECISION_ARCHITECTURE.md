# 🧬 Decision Architecture (Reviewer-oriented)

## 🎯 Purpose

Define how sample-level inclusion and grouping decisions are:
  
  - derived (rule-based)
- optionally overridden (manual)
- supported by evidence (QC)
- resolved into a single canonical inclusion

This document complements CONTRACT.md and POLICY.md.

---
  
  # 🧭 Core Principle
  
  > Decision is not a single step — it is a layered resolution process.

---
  
  # 🧱 Decision Layers
  
  ## Layer 1 — Metadata-derived Decision (Rule-based)
  
  Derived **only from metadata** (no expression allowed).

### Output fields

- group_candidate        # case / control / NA
- include_metadata       # TRUE / FALSE
- exclude_reason         # e.g., treated_sample / cell_line
- decision_source        # "rule"

### Properties

- deterministic
- reproducible
- no manual intervention

---
  
  ## Layer 2 — Manual Override (Exception Layer)
  
  Used only when metadata rules cannot correctly represent sample status.

### Storage

Recommended: separate file

  sample_metadata_override.tsv


### Fields

- sample_id
- override_include        # TRUE / FALSE / NA
- override_group_label    # case / control / NA
- override_reason         # REQUIRED
- override_by             # optional
- override_timestamp      # optional

### Rules

- MUST NOT be used for convenience
- MUST include human-readable reason
- SHOULD be rare

---
  
  ## Layer 3 — Pre-QC (Preprocessing Decision Support)
  
  Performed before preprocessing.

### Purpose

Determine whether preprocessing is required.

### Example checks

- value distribution (raw vs log-scale)
- quantile spread
- missingness overview

### Output (stored in manifest, not metadata)

- log2_required
- preqc_notes

### Important

Pre-QC does NOT exclude samples.

---
  
  ## Layer 4 — Preprocessing
  
  Conditional transformations:
  
  - log2 transformation
- normalization (if needed)

### Recorded in manifest

- log2_applied
- normalization_applied
- normalization_method

---
  
  ## Layer 5 — Post-QC (Evidence Layer)
  
  Performed after preprocessing.

### Purpose

Provide **evidence about sample quality**
  
  ### Example checks
  
  - PCA outlier detection
- sample-level missing rate

### Output

Stored in QC table:
  
  sample_qc_flags.tsv


Fields:
  
  - sample_id
- qc_flag       # PASS / OUTLIER / HIGH_MISSING / ...
- qc_reason
- qc_metric     # optional

### Important

QC does NOT directly modify inclusion.

---
  
  ## Layer 6 — Final Inclusion Resolution
  
  Single point where all decisions are resolved.

### Precedence (STRICT)

1. manual override
2. metadata exclusion
3. QC filter

### Logic

include_qc = qc_flag %in% allowed_flags

include_final =
  if override exists:
  override_include
else:
  include_metadata & include_qc


---
  
  ## 🎯 Canonical Output Rule
  
  Downstream pipeline MUST use only:
  
  sample_metadata_merged.tsv


### Required fields

- sample_id
- include        # FINAL inclusion only
- group_label    # FINAL grouping only

### Important

Intermediate fields MUST NOT leak into downstream modules.

---
  
  # 🧠 Design Philosophy
  
  ## 1. Rule first, manual last
  All decisions should be reproducible from rules unless explicitly overridden.

## 2. QC is evidence, not authority
QC informs decisions but does not directly control inclusion.

## 3. One final decision
Only one canonical `include` is exposed downstream.

## 4. All exceptions must be visible
Manual overrides must be explicit and traceable.

## 5. Separation of concerns

| Layer | Responsibility |
  |------|------|
  | Metadata | semantics |
  | Decision | grouping |
  | QC | evidence |
  | Final inclusion | resolution |
  
  ---
  
  # 🚫 Anti-patterns
  
  - Directly editing `include` without reason
- Using QC to silently drop samples
- Mixing metadata logic with expression data
- Recomputing decision inside downstream modules