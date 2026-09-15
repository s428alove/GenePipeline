#!/usr/bin/env Rscript

# ============================================================
# 99_run_V0.R
#
# Role:
#   V0 ingest orchestrator for GenePipeline.
#
# What this script does:
#   - Parse CLI arguments
#   - Resolve input/output paths
#   - Source helper modules from _lib/
#   - Read GEO Series Matrix
#   - Build probe-level expression matrix
#   - Parse raw sample metadata
#   - Run formal pre-QC before/after log2
#   - Apply log2 when needed for downstream canonical expression
#   - Resolve GPL annotation and build probe -> gene mapping
#   - Aggregate probe-level expression to gene-level expression
#   - Apply post-aggregation missing-value policy
#   - Write machine-readable missingness_gate.json for UI/backend use
#   - Build or normalize decision metadata table
#   - Preserve an existing decision table when sample IDs are unchanged
#   - Block reruns when an existing decision table no longer matches raw samples
#   - Merge AFTER-log2 pre-QC flags into decision metadata as review hints
#   - Run minimal V0 validation
#   - Write canonical V0 outputs + engineering records
# ============================================================

suppressPackageStartupMessages({
  library(optparse)
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(tidyr)
})

script_arg <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", script_arg, value = TRUE)
script_path <- if (length(file_arg) > 0) sub("^--file=", "", file_arg[1]) else ""
script_dir <- if (nzchar(script_path)) dirname(normalizePath(script_path, mustWork = FALSE)) else getwd()
lib_dir <- file.path(script_dir, "_lib")

source(file.path(lib_dir, "v0_io.R"))
source(file.path(lib_dir, "geo_series_matrix.R"))
source(file.path(lib_dir, "gpl_annotation.R"))
source(file.path(lib_dir, "pre_qc.R"))

# Apply the baseline post-aggregation missing-value policy.
#
# Policy:
#   - Write a traceable gene-level missingness report.
#   - Remove any gene containing one or more non-finite values.
#   - Stop if the removed-gene fraction exceeds the configured threshold.
#   - Never impute zero or use group-aware information.
apply_post_aggregation_missing_policy <- function(
  gene_mat,
  report_path,
  gse,
  max_removed_fraction = 0.05,
  quiet = FALSE
) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop2(
      "Missing required R package: jsonlite. ",
      "Restart GenePipeline to restore its package environment, then rerun V0."
    )
  }

  if (!is.matrix(gene_mat)) {
    gene_mat <- as.matrix(gene_mat)
  }

  if (!is.numeric(gene_mat)) {
    stop2("Gene-level expression matrix is not numeric after aggregation.")
  }

  if (nrow(gene_mat) == 0L || ncol(gene_mat) == 0L) {
    stop2("Gene-level expression matrix is empty before missing-value filtering.")
  }

  if (is.null(rownames(gene_mat)) || is.null(colnames(gene_mat))) {
    stop2("Gene-level expression matrix must have gene and sample names.")
  }

  if (
    length(max_removed_fraction) != 1L ||
    !is.finite(max_removed_fraction) ||
    max_removed_fraction < 0 ||
    max_removed_fraction > 1
  ) {
    stop2("--max_missing_gene_fraction must be a finite number between 0 and 1.")
  }

  n_genes_before <- nrow(gene_mat)
  n_samples <- ncol(gene_mat)

  nonfinite_by_gene <- rowSums(!is.finite(gene_mat))
  affected_idx <- which(nonfinite_by_gene > 0L)

  if (length(affected_idx) > 0L) {
    report <- tibble::tibble(
      gene_id = rownames(gene_mat)[affected_idx],
      n_missing_samples = as.integer(nonfinite_by_gene[affected_idx]),
      missing_fraction = as.numeric(nonfinite_by_gene[affected_idx] / n_samples),
      action = "removed",
      reason = "non_finite_after_probe_to_gene_aggregation"
    ) %>%
      dplyr::arrange(dplyr::desc(.data$n_missing_samples), .data$gene_id)
  } else {
    report <- tibble::tibble(
      gene_id = character(),
      n_missing_samples = integer(),
      missing_fraction = double(),
      action = character(),
      reason = character()
    )
  }

  ensure_dir(dirname(report_path))
  readr::write_tsv(report, report_path)

  n_genes_removed <- length(affected_idx)
  removed_fraction <- n_genes_removed / n_genes_before
  n_genes_after <- n_genes_before - n_genes_removed

  gate_status <- if (
    removed_fraction > max_removed_fraction
  ) {
    "review_required"
  } else {
    "passed"
  }

  # Round upward to the next whole percentage point for a UI-friendly
  # dataset-specific override suggestion. This is a suggestion only.
  recommended_minimum_threshold <- if (removed_fraction == 0) {
    0
  } else {
    ceiling(removed_fraction * 100) / 100
  }

  gate_path <- file.path(
    dirname(report_path),
    "missingness_gate.json"
  )

  gate_data <- list(
    schema_version = "1.0",
    stage = "v0_post_aggregation_missingness",
    status = gate_status,
    review_required = identical(gate_status, "review_required"),
    canonical_expression_ready = identical(gate_status, "passed"),
    gse = gse,
    policy = "complete_case_gene_filtering",
    genes_before = n_genes_before,
    genes_removed = n_genes_removed,
    genes_after = n_genes_after,
    samples = n_samples,
    removed_fraction = removed_fraction,
    configured_threshold = max_removed_fraction,
    recommended_minimum_threshold = recommended_minimum_threshold,
    report_path = report_path,
    timestamp = format(
      Sys.time(),
      "%Y-%m-%dT%H:%M:%S%z"
    )
  )

  jsonlite::write_json(
    gate_data,
    gate_path,
    auto_unbox = TRUE,
    pretty = TRUE,
    na = "null"
  )

  log_msg(
    "Post-aggregation missingness: ",
    n_genes_removed, "/", n_genes_before,
    " genes marked for removal (",
    format(round(removed_fraction * 100, 4), trim = TRUE),
    "%).",
    quiet = quiet
  )
  log_msg("Missingness report: ", report_path, quiet = quiet)
  log_msg(
    "Missingness gate: ", gate_path,
    " [status=", gate_status, "]",
    quiet = quiet
  )

  # The gate JSON must be written before this stop so the backend/UI can
  # distinguish review_required from an unexpected execution failure.
  if (removed_fraction > max_removed_fraction) {
    stop2(
      "Post-aggregation missing-value filtering would remove ",
      n_genes_removed, " of ", n_genes_before, " genes (",
      format(round(removed_fraction * 100, 4), trim = TRUE),
      "%), exceeding the configured threshold of ",
      format(round(max_removed_fraction * 100, 4), trim = TRUE),
      "%. Inspect raw expression, annotation, and probe-to-gene mapping. ",
      "Report written to: ", report_path, ". ",
      "Gate written to: ", gate_path
    )
  }

  keep <- nonfinite_by_gene == 0L
  gene_mat_clean <- gene_mat[keep, , drop = FALSE]

  if (nrow(gene_mat_clean) == 0L) {
    stop2(
      "No genes remain after post-aggregation missing-value filtering. ",
      "Report written to: ", report_path, ". ",
      "Gate written to: ", gate_path
    )
  }

  list(
    gene_mat = gene_mat_clean,
    report = report,
    report_path = report_path,
    gate = gate_data,
    gate_path = gate_path,
    gate_status = gate_status,
    policy = "complete_case_gene_filtering",
    n_genes_before = n_genes_before,
    n_genes_removed = n_genes_removed,
    removed_fraction = removed_fraction,
    n_genes_after = n_genes_after,
    max_removed_fraction = max_removed_fraction,
    recommended_minimum_threshold = recommended_minimum_threshold
  )
}


read_decision_metadata <- function(decision_path) {
  if (!file.exists(decision_path)) {
    stop2("Decision metadata file not found: ", decision_path)
  }

  delim <- ifelse(
    grepl("\\.csv$", decision_path, ignore.case = TRUE),
    ",",
    "\t"
  )

  decision_df <- suppressMessages(readr::read_delim(
    decision_path,
    delim = delim,
    show_col_types = FALSE,
    progress = FALSE,
    trim_ws = TRUE
  ))

  if (!("sample_id" %in% names(decision_df))) {
    cand <- intersect(
      names(decision_df),
      c("sample", "geo_accession", "GSM", "gsm", "accession")
    )

    if (length(cand) > 0) {
      decision_df <- decision_df %>%
        rename(sample_id = all_of(cand[1]))
    } else {
      stop2(
        "Decision metadata provided but no recognizable sample_id column found: ",
        decision_path
      )
    }
  }

  decision_df <- decision_df %>%
    mutate(sample_id = stringr::str_trim(as.character(.data$sample_id)))

  empty_ids <- which(is.na(decision_df$sample_id) | decision_df$sample_id == "")
  if (length(empty_ids) > 0) {
    stop2(
      "Decision metadata contains empty sample_id values: ",
      decision_path,
      ". Row numbers (up to 10): ",
      paste(head(empty_ids + 1L, 10), collapse = ", ")
    )
  }

  duplicated_ids <- unique(
    decision_df$sample_id[duplicated(decision_df$sample_id)]
  )
  if (length(duplicated_ids) > 0) {
    stop2(
      "Decision metadata contains duplicate sample_id values: ",
      decision_path,
      ". Examples: ",
      paste(head(duplicated_ids, 10), collapse = ", ")
    )
  }

  decision_df
}

validate_existing_decision_sample_set <- function(
  decision_df,
  sample_names,
  decision_path
) {
  current_ids <- stringr::str_trim(as.character(sample_names))
  decision_ids <- stringr::str_trim(as.character(decision_df$sample_id))

  missing_from_decision <- setdiff(current_ids, decision_ids)
  unknown_in_decision <- setdiff(decision_ids, current_ids)

  if (
    length(missing_from_decision) > 0 ||
    length(unknown_in_decision) > 0
  ) {
    details <- c(
      if (length(missing_from_decision) > 0) {
        paste0(
          "Missing from existing decision (up to 10): ",
          paste(head(missing_from_decision, 10), collapse = ", ")
        )
      },
      if (length(unknown_in_decision) > 0) {
        paste0(
          "Not present in current raw metadata (up to 10): ",
          paste(head(unknown_in_decision, 10), collapse = ", ")
        )
      }
    )

    stop2(
      "Existing decision file does not match the current raw metadata and ",
      "will not be overwritten: ",
      decision_path,
      ". ",
      paste(details, collapse = ". "),
      ". Archive or reconcile the existing decision file before rerunning V0."
    )
  }

  decision_df[match(current_ids, decision_ids), , drop = FALSE]
}

option_list <- list(
  make_option(c("--gse"), type = "character", help = "GSE accession, e.g. GSE13601"),
  make_option(c("--gpl"), type = "character", default = NA, help = "GPL accession (optional)"),
  make_option(c("--raw_dir"), type = "character", default = "data_raw", help = "Root folder containing raw GSE folders"),
  make_option(c("--out_dir"), type = "character", default = "data_processed", help = "Root folder for processed outputs"),
  make_option(c("--series_matrix"), type = "character", default = NA, help = "Explicit series matrix file path"),
  make_option(c("--annotation"), type = "character", default = NA, help = "Explicit annotation file path (.annot/.soft/.txt, optional)"),
  make_option(c("--metadata"), type = "character", default = NA, help = "Optional decision metadata path (tsv/txt/csv)"),
  make_option(c("--agg"), type = "character", default = "mean", help = "Probe->gene aggregation: mean|median|max"),
  make_option(c("--force_log2"), type = "character", default = "auto", help = "yes|no|auto"),
  make_option(
    c("--max_missing_gene_fraction"),
    type = "double",
    default = 0.05,
    help = "Maximum fraction of post-aggregation genes that may be removed for non-finite values [default: %default]"
  ),
  make_option(c("--quiet"), action = "store_true", default = FALSE, help = "Suppress log messages")
)

opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$gse) || opt$gse == "") stop2("Missing --gse.")

quiet <- isTRUE(opt$quiet)
gse   <- opt$gse

raw_gse_dir <- file.path(opt$raw_dir, gse)
out_gse_dir <- file.path(opt$out_dir, gse)
eng_dir     <- file.path(out_gse_dir, "_engineering")

if (!dir.exists(raw_gse_dir)) stop2("Raw GSE folder not found: ", raw_gse_dir)
ensure_dir(out_gse_dir)
ensure_dir(eng_dir)

series_path <- opt$series_matrix
if (is.na(series_path) || !nzchar(series_path)) {
  series_path <- find_file_conservative(raw_gse_dir, "series[_-]?matrix.*\\.(txt|tsv|gz)$")
}
if (is.na(series_path) || !nzchar(series_path) || !file.exists(series_path)) {
  stop2("Cannot find series matrix file in: ", raw_gse_dir)
}

log_msg("=== V0 RUN START ===", quiet = quiet)
log_msg("GSE: ", gse, quiet = quiet)
log_msg("Series matrix: ", series_path, quiet = quiet)

sm_lines <- read_text_lines(series_path, quiet = quiet)
sm <- read_series_matrix_to_probe_sample(sm_lines)
expr_mat <- sm$mat
sample_names <- sm$sample_names
raw_meta <- parse_sample_metadata_from_series_header(sm_lines, sample_names)
gpl_info <- extract_gpl_from_series_matrix(sm_lines, sample_names)

log_msg("Running formal pre-QC before/after log2 ...", quiet = quiet)
preqc <- run_preqc_before_after_log2(
  expr_mat = expr_mat,
  out_dir = eng_dir
)

annotation_path <- opt$annotation

resolved_gpl <- opt$gpl
if (is.na(resolved_gpl) || resolved_gpl == "") {
  if (length(gpl_info$gpl_candidates) == 1) {
    resolved_gpl <- gpl_info$gpl_candidates[[1]]
  } else if (length(gpl_info$gpl_candidates) > 1) {
    stop2(
      "Multiple GPL candidates found in Series Matrix header: ",
      paste(gpl_info$gpl_candidates, collapse = ", "),
      ". Please specify --gpl explicitly."
    )
  }
}

log2_needed  <- detect_log2_needed(as.numeric(expr_mat), method = opt$force_log2)
log2_applied <- FALSE

if (isTRUE(log2_needed)) {
  log_msg("Applying log2(x+1) for downstream canonical expression ...", quiet = quiet)
  expr_mat <- safe_log2(expr_mat)
  log2_applied <- TRUE
} else {
  log_msg("Log2 not applied (force_log2=", opt$force_log2, ").", quiet = quiet)
}

mapping_df <- NULL
annotation_resolved <- annotation_path

if (!is.na(annotation_path) && nzchar(annotation_path)) {
  if (!file.exists(annotation_path)) stop2("Annotation file not found: ", annotation_path)
  log_msg("Annotation (explicit): ", annotation_path, quiet = quiet)

  if (is.na(resolved_gpl) || resolved_gpl == "") {
    resolved_gpl <- infer_gpl_from_filename(annotation_path)
  }

  if (!exists("build_probe_to_gene_mapping_from_annotation", mode = "function")) {
    stop2("Expected public API build_probe_to_gene_mapping_from_annotation() not found in gpl_annotation.R")
  }

  built <- build_probe_to_gene_mapping_from_annotation(annotation_path, quiet = quiet)
  mapping_df <- built$mapping
  annotation_resolved <- built$annotation_path

} else {
  if (is.na(resolved_gpl) || resolved_gpl == "") {
    stop2(
      "Cannot auto-resolve annotation because GPL id is still unknown. ",
      "Provide --gpl or --annotation explicitly."
    )
  }

  log_msg("GPL: ", resolved_gpl, quiet = quiet)
  mapping_df <- get_probe_to_gene_mapping(
    gpl_id = resolved_gpl,
    raw_gse_dir = raw_gse_dir,
    cache_dir = eng_dir,
    quiet = quiet
  )

  annotation_resolved <- tryCatch(
    pick_annotation_by_gpl(resolved_gpl, raw_gse_dir, quiet = quiet),
    error = function(e) NA_character_
  )
}

gene_mat <- aggregate_probe_to_gene(expr_mat, mapping_df, agg = opt$agg)

gene_missingness_report_out <- file.path(eng_dir, "gene_missingness.tsv")

missing_filter <- apply_post_aggregation_missing_policy(
  gene_mat = gene_mat,
  report_path = gene_missingness_report_out,
  gse = gse,
  max_removed_fraction = opt$max_missing_gene_fraction,
  quiet = quiet
)

gene_mat <- missing_filter$gene_mat


decision_meta_out <- file.path(
  out_gse_dir,
  "sample_metadata_decision.tsv"
)

decision_path <- opt$metadata
decision_df <- NULL
decision_source <- ""
decision_source_path <- ""
decision_file_action <- ""
decision_backup_path <- ""

explicit_decision_supplied <- (
  !is.na(decision_path) &&
  nzchar(decision_path)
)

if (explicit_decision_supplied) {
  log_msg("Decision metadata (explicit): ", decision_path, quiet = quiet)

  decision_df <- read_decision_metadata(decision_path)
  decision_source <- "explicit_metadata"
  decision_source_path <- decision_path
  decision_file_action <- if (file.exists(decision_meta_out)) {
    "replaced_from_explicit_metadata"
  } else {
    "created_from_explicit_metadata"
  }
} else if (file.exists(decision_meta_out)) {
  log_msg(
    "Existing decision metadata detected; preserving manual decisions: ",
    decision_meta_out,
    quiet = quiet
  )

  decision_df <- read_decision_metadata(decision_meta_out)
  decision_df <- validate_existing_decision_sample_set(
    decision_df = decision_df,
    sample_names = sample_names,
    decision_path = decision_meta_out
  )

  decision_source <- "existing_decision"
  decision_source_path <- decision_meta_out
  decision_file_action <- "preserved_existing"
} else {
  decision_df <- tibble(
    sample_id    = sample_names,
    include      = "FALSE",
    group_label  = NA_character_,
    case_control = NA_character_,
    batch        = NA_character_,
    tissue       = NA_character_
  )

  decision_source <- "generated_template"
  decision_source_path <- ""
  decision_file_action <- "created"
}

if (!("include" %in% names(decision_df))) decision_df$include <- NA_character_
if (!("group_label" %in% names(decision_df))) decision_df$group_label <- NA_character_

decision_df$include <- normalize_include_to_tf(decision_df$include)
if (any(is.na(decision_df$include))) {
  bad <- decision_df$sample_id[is.na(decision_df$include)]
  stop2(
    "Decision include contains unrecognized values; cannot normalize to TRUE/FALSE. sample_id (up to 10): ",
    paste(head(bad, 10), collapse = ", ")
  )
}

missing_samples <- setdiff(sample_names, decision_df$sample_id)
if (length(missing_samples) > 0) {
  decision_df <- bind_rows(
    decision_df,
    tibble(sample_id = missing_samples, include = "FALSE", group_label = NA_character_)
  )
}

decision_df <- decision_df %>% filter(sample_id %in% sample_names)

if ("group" %in% names(decision_df) && !("case_control" %in% names(decision_df))) {
  decision_df <- decision_df %>% rename(case_control = group)
}

# preqc_flag and preqc_note are system-generated review hints.
# Refresh these columns on rerun while preserving all human-authored fields.
decision_df <- decision_df %>%
  select(-any_of(c("preqc_flag", "preqc_note")))

if (!is.null(preqc$after$sample_flags) && nrow(preqc$after$sample_flags) > 0) {
  preqc_decision_cols <- preqc$after$sample_flags %>%
    transmute(
      sample_id = sample_id,
      preqc_flag = if_else(preqc_flag_any, "TRUE", "FALSE"),
      preqc_note = preqc_note
    )

  decision_df <- decision_df %>%
    left_join(preqc_decision_cols, by = "sample_id")
}

required_first <- c("sample_id", "include", "group_label")
optional_cols  <- intersect(
  c("case_control", "contrast_id", "group_order", "reason_exclude", "batch", "tissue", "preqc_flag", "preqc_note"),
  names(decision_df)
)
other_cols <- setdiff(names(decision_df), c(required_first, optional_cols))
decision_df <- decision_df %>% select(all_of(required_first), all_of(optional_cols), all_of(other_cols))

validate_v0_minimal(gene_mat = gene_mat, raw_meta = raw_meta, decision_df = decision_df)

expr_out     <- file.path(out_gse_dir, "expression_gene_log.tsv")
raw_meta_out <- file.path(out_gse_dir, "sample_metadata_raw.tsv")

expr_tbl <- as.data.frame(
  gene_mat,
  check.names = FALSE
) %>%
  rownames_to_column("gene_id")

readr::write_tsv(expr_tbl, expr_out)
readr::write_tsv(raw_meta, raw_meta_out)

if (
  identical(decision_source, "existing_decision") &&
  file.exists(decision_meta_out)
) {
  decision_backup_dir <- file.path(
    eng_dir,
    "decision_backups"
  )
  ensure_dir(decision_backup_dir)

  decision_backup_path <- file.path(
    decision_backup_dir,
    paste0(
      "sample_metadata_decision_",
      format(Sys.time(), "%Y%m%d_%H%M%S"),
      "_pid",
      Sys.getpid(),
      ".tsv"
    )
  )

  backup_ok <- file.copy(
    from = decision_meta_out,
    to = decision_backup_path,
    overwrite = FALSE
  )

  if (!isTRUE(backup_ok)) {
    stop2(
      "Could not back up existing decision file before refresh: ",
      decision_meta_out
    )
  }
}

readr::write_tsv(decision_df, decision_meta_out)

summary_out      <- file.path(eng_dir, "V0_summary.txt")
session_info_out <- file.path(eng_dir, "sessionInfo.txt")
run_manifest_out <- file.path(eng_dir, "run_manifest.txt")

map_feature_col <- if ("feature_id" %in% names(mapping_df)) "feature_id" else if ("probe" %in% names(mapping_df)) "probe" else NA_character_
map_status_col  <- if ("map_status" %in% names(mapping_df)) "map_status" else NA_character_

n_feature_mapped_ok <- NA_integer_
if (!is.na(map_feature_col)) {
  if (!is.na(map_status_col)) {
    n_feature_mapped_ok <- mapping_df %>%
      filter(.data[[map_feature_col]] %in% rownames(expr_mat), .data[[map_status_col]] == "OK") %>%
      distinct(.data[[map_feature_col]]) %>%
      nrow()
  } else {
    n_feature_mapped_ok <- mapping_df %>%
      filter(.data[[map_feature_col]] %in% rownames(expr_mat)) %>%
      distinct(.data[[map_feature_col]]) %>%
      nrow()
  }
}

write_summary(summary_out, list(
  gse = gse,
  gpl = ifelse(is.na(resolved_gpl), "", resolved_gpl),
  series_matrix = series_path,
  annotation = ifelse(is.na(annotation_resolved), "", annotation_resolved),
  agg = opt$agg,
  force_log2 = opt$force_log2,
  log2_applied = log2_applied,
  n_feature_raw = nrow(expr_mat),
  n_feature_mapped_ok = n_feature_mapped_ok,
  missing_value_policy = missing_filter$policy,
  max_missing_gene_fraction = missing_filter$max_removed_fraction,
  n_gene_before_missing_filter = missing_filter$n_genes_before,
  n_gene_removed_missing = missing_filter$n_genes_removed,
  removed_gene_fraction = missing_filter$removed_fraction,
  n_gene_out = nrow(gene_mat),
  n_samples = ncol(gene_mat),
  gene_missingness_report = gene_missingness_report_out,
  decision_source = decision_source,
  decision_file_action = decision_file_action,
  decision_backup_path = decision_backup_path,
  missingness_gate = missing_filter$gate_path,
  missingness_gate_status = missing_filter$gate_status,
  recommended_minimum_missing_gene_fraction = missing_filter$recommended_minimum_threshold,
  feature_space = "gene"
))

write_session_info(session_info_out)

write_manifest(run_manifest_out, list(
  run_id = paste0(gse, "_", format(Sys.time(), "%Y%m%d_%H%M%S")),
  timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
  gse = gse,
  gpl = ifelse(is.na(resolved_gpl), "", resolved_gpl),
  series_matrix = series_path,
  annotation = ifelse(is.na(annotation_resolved), "", annotation_resolved),
  decision_path = decision_source_path,
  decision_source = decision_source,
  decision_file_action = decision_file_action,
  decision_backup_path = decision_backup_path,
  agg = opt$agg,
  force_log2 = opt$force_log2,
  log2_applied = log2_applied,
  feature_space = "gene",
  n_probe_raw = nrow(expr_mat),
  n_probe_mapped = n_feature_mapped_ok,
  missing_value_policy = missing_filter$policy,
  max_missing_gene_fraction = missing_filter$max_removed_fraction,
  n_gene_before_missing_filter = missing_filter$n_genes_before,
  n_gene_removed_missing = missing_filter$n_genes_removed,
  removed_gene_fraction = missing_filter$removed_fraction,
  n_gene_out = nrow(gene_mat),
  n_samples = ncol(gene_mat),
  gene_missingness_report = gene_missingness_report_out,
  missingness_gate = missing_filter$gate_path,
  missingness_gate_status = missing_filter$gate_status,
  recommended_minimum_missing_gene_fraction = missing_filter$recommended_minimum_threshold,
  expr_out = expr_out,
  raw_meta_out = raw_meta_out,
  decision_meta_out = decision_meta_out,
  summary_out = summary_out,
  session_info_out = session_info_out
))

log_msg("GPL: ", ifelse(is.na(resolved_gpl) || resolved_gpl == "", "<unknown>", resolved_gpl), quiet = quiet)

if (!is.null(preqc$after$sample_flags)) {
  n_flagged_after <- sum(preqc$after$sample_flags$preqc_flag_any, na.rm = TRUE)
  log_msg("Pre-QC flagged samples after log2: ", n_flagged_after, quiet = quiet)
}

log_msg("Wrote: ", expr_out, quiet = quiet)
log_msg("Wrote: ", gene_missingness_report_out, quiet = quiet)
log_msg("Wrote: ", missing_filter$gate_path, quiet = quiet)
log_msg("Wrote: ", raw_meta_out, quiet = quiet)

if (identical(decision_file_action, "preserved_existing")) {
  log_msg(
    "Preserved manual decision fields and refreshed pre-QC hints: ",
    decision_meta_out,
    quiet = quiet
  )
  log_msg(
    "Decision backup: ",
    decision_backup_path,
    quiet = quiet
  )
} else {
  log_msg(
    "Wrote decision metadata [",
    decision_file_action,
    "]: ",
    decision_meta_out,
    quiet = quiet
  )
}

if (!is.null(preqc$before$output_paths)) {
  log_msg("Wrote: ", preqc$before$output_paths$summary_out, quiet = quiet)
}
if (!is.null(preqc$after$output_paths)) {
  log_msg("Wrote: ", preqc$after$output_paths$summary_out, quiet = quiet)
}
if (!is.null(preqc$comparison_paths)) {
  log_msg("Wrote: ", preqc$comparison_paths$comparison_tsv, quiet = quiet)
  log_msg("Wrote: ", preqc$comparison_paths$comparison_txt, quiet = quiet)
  log_msg("Wrote: ", preqc$comparison_paths$interpretation_summary_txt, quiet = quiet)
}

log_msg("Wrote: ", summary_out, quiet = quiet)
log_msg("Wrote: ", run_manifest_out, quiet = quiet)
log_msg("Wrote: ", session_info_out, quiet = quiet)
log_msg("=== V0 RUN DONE ===", quiet = quiet)
