#!/usr/bin/env Rscript

# ============================================================
# 00_make_sample_metadata_merged.R  (FULL OVERWRITE)
# - Merge sample_metadata_raw.tsv + sample_metadata_decision.tsv
# - Enforce CONTRACT rules:
#   * include normalized to "TRUE"/"FALSE" (uppercase)
#   * raw LEFT JOIN decision by sample_id
#   * include==TRUE requires non-empty group_label
# - Optional:
#   * dataset_decision.tsv gate (v1_eligible / aliases) must be TRUE to proceed
#   * validate expression_gene_log.tsv columns are covered by merged meta
#     (supports V0 expression format: gene_id, feature_ids, n_features, <samples...>)
# ============================================================

suppressPackageStartupMessages({
  library(optparse)
  library(readr)
  library(dplyr)
  library(stringr)
})

stop2 <- function(...) stop(paste0(..., collapse = ""), call. = FALSE)

# ---- helpers ----
normalize_include_to_tf <- function(x) {
  # output: "TRUE"/"FALSE" (uppercase); NA if unrecognized
  if (is.logical(x)) return(ifelse(is.na(x), NA_character_, ifelse(x, "TRUE", "FALSE")))
  x0 <- as.character(x)
  x1 <- str_trim(tolower(x0))
  
  out <- rep(NA_character_, length(x1))
  out[x1 %in% c("true","t","1","yes","y","include","included","ok","go","run")] <- "TRUE"
  out[x1 %in% c("false","f","0","no","n","exclude","excluded","stop","skip")] <- "FALSE"
  out
}

normalize_case_control <- function(x) {
  # strict: only case/control/other; everything else -> NA
  x1 <- str_trim(tolower(as.character(x)))
  x1[x1 == ""] <- NA_character_
  
  out <- rep(NA_character_, length(x1))
  out[x1 %in% c("case")] <- "case"
  out[x1 %in% c("control")] <- "control"
  out[x1 %in% c("other")] <- "other"
  out
}

read_tsv_header_only <- function(path) {
  hdr <- readLines(path, n = 1, warn = FALSE)
  if (length(hdr) == 0) stop2("Cannot read header from: ", path)
  strsplit(hdr, "\t", fixed = TRUE)[[1]]
}

# dataset decision gate:
# - expects dataset_decision.tsv exists
# - looks for a gate column among aliases
# - normalize to TRUE/FALSE and require TRUE to continue
get_dataset_enter_v1_flag <- function(df, path, gse) {
  # 1) require gse column (case-insensitive)
  if (!("gse" %in% tolower(names(df)))) {
    stop2(
      "dataset_decision.tsv must contain a 'gse' column.\n",
      "File: ", path, "\n",
      "Current header: ", paste(names(df), collapse = "\t"), "\n"
    )
  }
  gse_col <- names(df)[tolower(names(df)) == "gse"][1]
  
  # 2) filter to this dataset
  df1 <- df %>%
    mutate(.gse = as.character(.data[[gse_col]])) %>%
    filter(.gse == gse)
  
  if (nrow(df1) == 0) {
    stop2(
      "dataset_decision has no row for this GSE.\n",
      "File: ", path, "\n",
      "Expected gse == ", gse, "\n"
    )
  }
  if (nrow(df1) > 1) {
    stop2(
      "dataset_decision has multiple rows for this GSE; expected exactly 1.\n",
      "File: ", path, "\n",
      "GSE: ", gse, "\n",
      "Rows: ", nrow(df1), "\n",
      "Fix: keep one row per GSE (after you decide GPL/feature_space).\n"
    )
  }
  
  # 3) locate gate column (includes v1_eligible)
  aliases <- c(
    "v1_eligible", "enter_v1", "proceed_v1", "v1", "allow_v1", "enable_v1",
    "run_v1", "analysis_ready", "run", "include"
  )
  
  nms <- names(df1)
  nms_lc <- tolower(nms)
  hit_idx <- which(nms_lc %in% aliases)
  
  if (length(hit_idx) == 0) {
    stop2(
      "dataset_decision missing a V1 gate column.\n",
      "File: ", path, "\n",
      "Expected one of: ", paste(aliases, collapse = ", "), "\n",
      "Current header: ", paste(nms, collapse = "\t"), "\n"
    )
  }
  
  gate_col <- nms[hit_idx[1]]
  flag <- normalize_include_to_tf(df1[[gate_col]])
  
  if (any(is.na(flag))) {
    stop2(
      "dataset_decision gate column contains unrecognized values; cannot normalize to TRUE/FALSE.\n",
      "File: ", path, "\n",
      "Column: ", gate_col, "\n",
      "Value: ", as.character(df1[[gate_col]][1]), "\n"
    )
  }
  
  list(flag = flag[1], gate_col = gate_col)
}

# Try to infer which columns in expression_gene_log.tsv are sample IDs.
# Supports current V0 format:
#   gene_id, feature_ids, n_features, <samples...>
infer_expr_sample_cols <- function(header_vec) {
  if (length(header_vec) < 2) return(character(0))
  
  # Prefer explicit known first columns (current V0)
  if (length(header_vec) >= 3 && header_vec[1] == "gene_id" &&
      header_vec[2] == "feature_ids" && header_vec[3] == "n_features") {
    return(header_vec[-c(1,2,3)])
  }
  
  # Backward compatible: if only gene_id then samples start at 2
  if (header_vec[1] == "gene_id") {
    return(header_vec[-1])
  }
  
  # Fallback: treat everything except first column as samples
  header_vec[-1]
}

# ---- CLI ----
option_list <- list(
  make_option(c("--gse"), type = "character", help = "GSE accession, e.g. GSE13601"),
  make_option(c("--out_dir"), type = "character", default = "data_processed", help = "Processed data root"),
  make_option(c("--check_expr"), action = "store_true", default = TRUE,
              help = "If expression_gene_log.tsv exists, validate sample_id covers expression columns"),
  make_option(c("--require_dataset_decision"), action = "store_true", default = TRUE,
              help = "Require dataset_decision.tsv and pass V1 gate before writing merged")
)

opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$gse) || opt$gse == "") stop2("Missing --gse")

gse <- opt$gse
out_gse_dir <- file.path(opt$out_dir, gse)

raw_path     <- file.path(out_gse_dir, "sample_metadata_raw.tsv")
dec_path     <- file.path(out_gse_dir, "sample_metadata_decision.tsv")
expr_path    <- file.path(out_gse_dir, "expression_gene_log.tsv")
merged_path  <- file.path(out_gse_dir, "sample_metadata_merged.tsv")
dsdec_path   <- file.path(out_gse_dir, "dataset_decision.tsv")

if (!file.exists(raw_path)) stop2("Not found: ", raw_path)
if (!file.exists(dec_path)) stop2("Not found: ", dec_path)

# ---- dataset-level V1 gate (入口) ----
if (isTRUE(opt$require_dataset_decision)) {
  if (!file.exists(dsdec_path)) {
    stop2(
      "Not found: ", dsdec_path, "\n",
      "V1 entry requires dataset_decision.tsv (set --require_dataset_decision=FALSE to bypass, not recommended).\n"
    )
  }
  dsdec <- readr::read_tsv(dsdec_path, show_col_types = FALSE)
  gate <- get_dataset_enter_v1_flag(dsdec, dsdec_path, gse)
  
  if (gate$flag != "TRUE") {
    stop2(
      "Dataset blocked from entering V1 by dataset_decision.\n",
      "File: ", dsdec_path, "\n",
      "Gate column: ", gate$gate_col, "\n",
      "Value: ", gate$flag, "\n",
      "Action: set gate to TRUE if you want to proceed.\n"
    )
  }
  cat("Dataset V1 gate PASS (", gate$gate_col, "=TRUE)\n", sep = "")
}

# ---- load ----
raw <- readr::read_tsv(raw_path, show_col_types = FALSE)
dec <- readr::read_tsv(dec_path, show_col_types = FALSE)

# ---- standardize raw schema ----
if (!("sample_id" %in% names(raw))) {
  cand <- intersect(names(raw), c("sample", "GSM", "gsm", "geo_accession", "accession"))
  if (length(cand) > 0) raw <- raw %>% rename(sample_id = all_of(cand[1]))
  else stop2("Raw metadata missing sample_id (or recognizable alias). File: ", raw_path)
}
raw <- raw %>% mutate(sample_id = as.character(sample_id))

# ---- standardize decision schema ----
if (!("sample_id" %in% names(dec))) {
  cand <- intersect(names(dec), c("sample", "GSM", "gsm", "geo_accession", "accession"))
  if (length(cand) > 0) dec <- dec %>% rename(sample_id = all_of(cand[1]))
  else stop2("Decision metadata missing sample_id (or recognizable alias). File: ", dec_path)
}
dec <- dec %>% mutate(sample_id = as.character(sample_id))

# required-ish columns
if (!("include" %in% names(dec))) dec$include <- NA_character_
if (!("group_label" %in% names(dec))) dec$group_label <- NA_character_
if (!("case_control" %in% names(dec))) dec$case_control <- NA_character_

# normalize include to TRUE/FALSE (uppercase) -- required for merged contract
dec$include <- normalize_include_to_tf(dec$include)
if (any(is.na(dec$include))) {
  bad <- dec$sample_id[is.na(dec$include)]
  stop2(
    "Decision include contains unrecognized values; cannot normalize to TRUE/FALSE.\n",
    "Fix sample_metadata_decision.tsv include column first.\n",
    "sample_id (up to 10): ", paste(head(bad, 10), collapse = ", ")
  )
}

# normalize case_control (strict)
dec$case_control <- normalize_case_control(dec$case_control)

# ---- uniqueness checks ----
if (any(is.na(raw$sample_id) | str_trim(raw$sample_id) == "")) stop2("Raw metadata has NA/empty sample_id.")
if (any(is.na(dec$sample_id) | str_trim(dec$sample_id) == "")) stop2("Decision table has NA/empty sample_id.")

if (any(duplicated(raw$sample_id))) {
  dup <- unique(raw$sample_id[duplicated(raw$sample_id)])
  stop2("Raw metadata has duplicated sample_id. Example: ", paste(head(dup, 10), collapse = ", "))
}
if (any(duplicated(dec$sample_id))) {
  dup <- unique(dec$sample_id[duplicated(dec$sample_id)])
  stop2("Decision table has duplicated sample_id. Example: ", paste(head(dup, 10), collapse = ", "))
}

# ---- merge rule (CONTRACT): raw LEFT JOIN decision ----
merged <- raw %>%
  left_join(dec, by = "sample_id")

# ---- column order: required fields first ----
front <- intersect(c("sample_id", "include", "case_control", "group_label"), names(merged))
merged <- merged %>% select(all_of(front), everything())

# ---- validations (merge-level) ----
if (!("include" %in% names(merged))) stop2("Merged missing include column (unexpected).")
if (any(is.na(merged$include))) {
  miss <- merged$sample_id[is.na(merged$include)]
  stop2(
    "Decision table incomplete: include is NA after merge for sample_id.\n",
    "You likely have samples in raw metadata that are missing from decision.\n",
    "sample_id (up to 10): ", paste(head(miss, 10), collapse = ", ")
  )
}

if (sum(merged$include == "TRUE", na.rm = TRUE) == 0) {
  stop2("Merged invalid: include is all FALSE. Set include==TRUE for samples you want to analyze.")
}

bad_grp <- merged$sample_id[
  merged$include == "TRUE" & (is.na(merged$group_label) | str_trim(as.character(merged$group_label)) == "")
]
if (length(bad_grp) > 0) {
  stop2(
    "Merged invalid: group_label required for include==TRUE.\n",
    "sample_id (up to 10): ", paste(head(bad_grp, 10), collapse = ", ")
  )
}

# Optional: validate expression sample columns are covered by merged meta
if (isTRUE(opt$check_expr) && file.exists(expr_path)) {
  hdr <- read_tsv_header_only(expr_path)
  if (length(hdr) < 2) stop2("Expression header too small: ", expr_path)
  
  expr_samples <- infer_expr_sample_cols(hdr)
  if (length(expr_samples) == 0) stop2("Could not infer expression sample columns from header: ", expr_path)
  
  miss_meta <- setdiff(expr_samples, merged$sample_id)
  if (length(miss_meta) > 0) {
    stop2(
      "Alignment invalid: expression columns missing in merged metadata sample_id.\n",
      "sample_id (up to 10): ", paste(head(miss_meta, 10), collapse = ", "), "\n",
      "Hint: check sample_id normalization in raw/decision, or expression file header.\n"
    )
  }
}

# ---- write ----
readr::write_tsv(merged, merged_path)

cat("Wrote: ", merged_path, "\n", sep = "")
cat("Rows: ", nrow(merged), "\n", sep = "")
cat("Included (TRUE): ", sum(merged$include == "TRUE"), "\n", sep = "")

gl <- merged$group_label[merged$include == "TRUE"]
cat("Group levels among included: ",
    paste(sort(unique(gl)), collapse = ", "),
    "\n", sep = "")

cc <- merged$case_control[merged$include == "TRUE"]
cc_levels <- sort(unique(na.omit(cc)))
cat("case_control levels among included (may be incomplete until filled): ",
    if (length(cc_levels) == 0) "NA" else paste(cc_levels, collapse = ", "),
    "\n", sep = "")
