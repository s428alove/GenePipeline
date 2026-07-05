#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(readr)
  library(dplyr)
  library(stringr)
})

stop2 <- function(...) stop(paste0(..., collapse=""), call.=FALSE)

# ---------- helper: alias normalize ----------
resolve_column <- function(df, candidates, new_name) {
  for (c in candidates) {
    if (c %in% names(df)) {
      df <- df %>% rename(!!new_name := all_of(c))
      return(df)
    }
  }
  df[[new_name]] <- NA_character_
  df
}

# ---------- main ----------
build_decision_candidates <- function(meta_raw, qc=NULL, decision=NULL, override=NULL, out_dir) {
  
  raw <- read_tsv(meta_raw, show_col_types = FALSE)
  
  # alias normalize
  raw <- resolve_column(raw, c("sample_id","sample","gsm","geo_accession"), "sample_id")
  raw <- resolve_column(raw, c("title","sample_title"), "title")
  raw <- resolve_column(raw, c("source_name_ch1","source_name","source"), "source_name_ch1")
  raw <- resolve_column(raw, c("characteristics","characteristics_ch1"), "characteristics")
  
  # ---- decision (optional)
  if (!is.null(decision) && file.exists(decision)) {
    dec <- read_tsv(decision, show_col_types = FALSE)
    dec <- resolve_column(dec, c("sample_id","sample","gsm"), "sample_id")
    
    if (!"include" %in% names(dec)) dec$include <- NA
    if (!"group_label" %in% names(dec)) dec$group_label <- NA
    if (!"case_control" %in% names(dec)) dec$case_control <- NA
    if (!"reason_exclude" %in% names(dec)) dec$reason_exclude <- NA
    
    dec <- dec %>%
      rename(
        include_existing = include,
        group_label_existing = group_label,
        case_control_existing = case_control,
        reason_exclude_existing = reason_exclude
      )
    
  } else {
    dec <- data.frame(
      sample_id = raw$sample_id,
      include_existing = NA,
      group_label_existing = NA,
      case_control_existing = NA,
      reason_exclude_existing = NA
    )
  }
  
  # ---- override (optional)
  if (!is.null(override) && file.exists(override)) {
    ov <- read_tsv(override, show_col_types = FALSE)
    ov <- resolve_column(ov, c("sample_id","sample","gsm"), "sample_id")
    
    if (!"override_include" %in% names(ov)) ov$override_include <- NA
    if (!"override_group_label" %in% names(ov)) ov$override_group_label <- NA
    if (!"override_reason" %in% names(ov)) ov$override_reason <- NA
    
    ov <- ov %>%
      rename(
        override_include_existing = override_include,
        override_group_label_existing = override_group_label,
        override_reason_existing = override_reason
      )
    
  } else {
    ov <- data.frame(
      sample_id = raw$sample_id,
      override_include_existing = NA,
      override_group_label_existing = NA,
      override_reason_existing = NA
    )
  }
  
  # ---- qc (optional)
  if (!is.null(qc) && file.exists(qc)) {
    qc_df <- read_tsv(qc, show_col_types = FALSE)
    qc_df <- resolve_column(qc_df, c("sample_id","sample","gsm"), "sample_id")
    
    if (!"qc_flag" %in% names(qc_df)) qc_df$qc_flag <- NA
    if (!"qc_reason" %in% names(qc_df)) qc_df$qc_reason <- NA
    
  } else {
    qc_df <- data.frame(
      sample_id = raw$sample_id,
      qc_flag = NA,
      qc_reason = NA
    )
  }
  
  # ---- merge all
  candidate_tbl <- raw %>%
    left_join(dec, by="sample_id") %>%
    left_join(ov, by="sample_id") %>%
    left_join(qc_df, by="sample_id") %>%
    mutate(
      has_existing_decision = !is.na(include_existing) |
        !is.na(group_label_existing) |
        !is.na(case_control_existing),
      has_existing_override = !is.na(override_include_existing),
      has_qc_flag = !is.na(qc_flag)
    )
  
  # ---- write
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  
  out_path <- file.path(out_dir, "sample_metadata_decision_candidates.tsv")
  write_tsv(candidate_tbl, out_path)
  
  cat("Wrote:", out_path, "\n")
}

# ---------- CLI ----------
option_list <- list(
  make_option("--gse", type="character"),
  make_option("--meta_raw", type="character"),
  make_option("--decision", type="character", default=NULL),
  make_option("--override", type="character", default=NULL),
  make_option("--qc", type="character", default=NULL),
  make_option("--out", type="character")
)

opt <- parse_args(OptionParser(option_list=option_list))

build_decision_candidates(
  meta_raw = opt$meta_raw,
  qc = opt$qc,
  decision = opt$decision,
  override = opt$override,
  out_dir = opt$out
)