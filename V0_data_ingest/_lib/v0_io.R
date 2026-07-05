# ============================================================
# V0_data_ingest/_lib/v0_io.R
#
# Role:
#   Shared helpers for V0 ingest.
#
# Responsibility:
#   1. Logging / fail-fast helpers
#   2. Directory and file/path helpers
#   3. Text reader helper (shared by GEO and GPL parsers)
#   4. log2 detection / conversion
#   5. probe -> gene aggregation
#   6. include normalization
#   7. minimal validation
#   8. summary / manifest / session info writing
#
# Design choice:
#   Common helpers are centralized here so geo_series_matrix.R and
#   gpl_annotation.R do not keep their own duplicated versions.
#
# Update note:
#   This rewritten version makes summary / manifest writing NA-safe,
#   so optional fields do not crash when values are missing.
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(tibble)
})

# ------------------------------------------------------------
# stop2()
# Fail-fast helper that concatenates message fragments.
# ------------------------------------------------------------
stop2 <- function(...) stop(paste0(..., collapse = ""), call. = FALSE)

# ------------------------------------------------------------
# log_msg()
# Simple timestamped console logger.
# ------------------------------------------------------------
log_msg <- function(..., quiet = FALSE) {
  if (!quiet) {
    cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), ..., "\n", sep = "")
  }
}

# ------------------------------------------------------------
# ensure_dir()
# Create directory if missing.
# ------------------------------------------------------------
ensure_dir <- function(path) {
  if (!dir.exists(path)) dir.create(path, recursive = TRUE, showWarnings = FALSE)
  invisible(TRUE)
}

# ------------------------------------------------------------
# .as_scalar_string()
#
# Purpose:
#   Convert a value into a safe single string for text outputs.
#
# Rules:
#   - NULL -> default
#   - length 0 -> default
#   - NA -> default
#   - everything else -> as.character(first element)
# ------------------------------------------------------------
.as_scalar_string <- function(x, default = "") {
  if (is.null(x) || length(x) == 0) return(default)
  x1 <- x[[1]]
  if (is.na(x1)) return(default)
  as.character(x1)
}

# ------------------------------------------------------------
# .has_text()
#
# Purpose:
#   NA-safe test for whether a value is a non-empty string.
# ------------------------------------------------------------
.has_text <- function(x) {
  x1 <- .as_scalar_string(x, default = "")
  nzchar(x1)
}

# ------------------------------------------------------------
# .kv_line()
#
# Purpose:
#   Build a "Key: value" text line.
# ------------------------------------------------------------
.kv_line <- function(key, value) {
  paste0(key, value)
}

# ------------------------------------------------------------
# .optional_kv_line()
#
# Purpose:
#   Build a text line only when the value is non-empty.
# ------------------------------------------------------------
.optional_kv_line <- function(key, value) {
  value1 <- .as_scalar_string(value, default = "")
  if (!nzchar(value1)) return(NULL)
  paste0(key, value1)
}

# ------------------------------------------------------------
# read_text_lines()
#
# Purpose:
#   Shared text reader for plain text and .gz files.
#   Used by both Series Matrix parsing and GPL parsing.
# ------------------------------------------------------------
read_text_lines <- function(path, quiet = FALSE) {
  if (missing(path) || is.null(path) || is.na(path) || !nzchar(path)) {
    stop2("read_text_lines(): path is empty.")
  }
  if (!file.exists(path)) {
    stop2("read_text_lines(): file not found: ", path)
  }

  log_msg("Reading lines: ", path, quiet = quiet)

  con <- if (grepl("\\.gz$", path, ignore.case = TRUE)) gzfile(path, "rt") else file(path, "rt")
  on.exit(close(con), add = TRUE)
  readLines(con, warn = FALSE)
}

# ------------------------------------------------------------
# find_file_conservative()
#
# Purpose:
#   Search only the top-level of a directory and return the first file
#   whose basename matches the regex.
# ------------------------------------------------------------
find_file_conservative <- function(dir, regex) {
  if (missing(dir) || is.null(dir) || is.na(dir) || !nzchar(dir)) return(NA_character_)
  if (!dir.exists(dir)) return(NA_character_)

  files <- list.files(dir, full.names = TRUE, recursive = FALSE)
  hits <- files[grepl(regex, basename(files), ignore.case = TRUE)]

  if (length(hits) == 0) return(NA_character_)
  hits[1]
}

# ------------------------------------------------------------
# infer_gpl_from_filename()
#
# Purpose:
#   Extract GPL accession such as GPL570 from a file basename.
# ------------------------------------------------------------
infer_gpl_from_filename <- function(path) {
  if (missing(path) || is.null(path) || is.na(path) || !nzchar(path)) return(NA_character_)
  bn <- basename(path)
  m <- stringr::str_match(bn, "(GPL\\d+)")
  if (is.na(m[1, 2])) return(NA_character_)
  m[1, 2]
}

# ------------------------------------------------------------
# detect_log2_needed()
# Heuristic only; user explicit option still overrides.
# ------------------------------------------------------------
detect_log2_needed <- function(x, method = "auto") {
  method <- tolower(method)
  if (method %in% c("yes", "true", "1")) return(TRUE)
  if (method %in% c("no", "false", "0")) return(FALSE)

  suppressWarnings({
    mx <- max(x, na.rm = TRUE)
    mn <- min(x, na.rm = TRUE)
  })

  if (!is.finite(mx) || !is.finite(mn)) return(FALSE)
  if (mn < 0) return(FALSE)
  if (mx > 50) return(TRUE)

  FALSE
}

# ------------------------------------------------------------
# safe_log2()
# Use log2(x + 1) to avoid -Inf from zeros.
# ------------------------------------------------------------
safe_log2 <- function(mat) log2(mat + 1)

# ------------------------------------------------------------
# aggregate_probe_to_gene()
#
# Supports both old and new mapping schemas:
#   old: probe / gene
#   new: feature_id / gene_id / map_status
# ------------------------------------------------------------
aggregate_probe_to_gene <- function(expr_mat, mapping_df, agg = "mean") {
  agg <- tolower(agg)
  if (!agg %in% c("mean", "median", "max")) stop2("Unsupported agg.")

  if (is.null(rownames(expr_mat)) || nrow(expr_mat) == 0) {
    stop2("Expression matrix empty or missing rownames.")
  }

  if ("feature_id" %in% names(mapping_df)) {
    map_feature_col <- "feature_id"
  } else if ("probe" %in% names(mapping_df)) {
    map_feature_col <- "probe"
  } else {
    stop2("mapping_df missing feature id column (expected feature_id or probe).")
  }

  if ("gene_id" %in% names(mapping_df)) {
    map_gene_col <- "gene_id"
  } else if ("gene" %in% names(mapping_df)) {
    map_gene_col <- "gene"
  } else {
    stop2("mapping_df missing gene id column (expected gene_id or gene).")
  }

  map_has_status <- "map_status" %in% names(mapping_df)
  feats_in_expr <- rownames(expr_mat)

  m <- mapping_df %>%
    mutate(
      feature_id = as.character(.data[[map_feature_col]]),
      gene_id    = as.character(.data[[map_gene_col]])
    ) %>%
    { if (map_has_status) mutate(., map_status = as.character(map_status)) else mutate(., map_status = "OK") } %>%
    filter(feature_id %in% feats_in_expr) %>%
    filter(!is.na(gene_id), gene_id != "") %>%
    filter(map_status == "OK") %>%
    select(feature_id, gene_id) %>%
    distinct()

  if (nrow(m) == 0) {
    stop2("No overlapping/usable mappings between expression matrix and annotation mapping.")
  }

  expr_df <- as.data.frame(expr_mat, stringsAsFactors = FALSE, check.names = FALSE) %>%
    tibble::rownames_to_column("feature_id")

  sample_cols <- setdiff(names(expr_df), "feature_id")

  expr_df <- expr_df %>%
    mutate(across(all_of(sample_cols), ~ suppressWarnings(as.numeric(.x))))

  joined <- m %>% inner_join(expr_df, by = "feature_id")

  # Aggregate only finite values. If a gene/sample combination has no
  # finite probe values, return NA explicitly so validation can stop V0
  # with a clear diagnostic instead of writing NaN/-Inf downstream.
  agg_fun <- switch(
    agg,
    mean = function(x) {
      x <- x[is.finite(x)]
      if (length(x) == 0L) NA_real_ else mean(x)
    },
    median = function(x) {
      x <- x[is.finite(x)]
      if (length(x) == 0L) NA_real_ else stats::median(x)
    },
    max = function(x) {
      x <- x[is.finite(x)]
      if (length(x) == 0L) NA_real_ else max(x)
    }
  )

  gene_df <- joined %>%
    group_by(gene_id) %>%
    summarise(across(all_of(sample_cols), agg_fun), .groups = "drop")

  gene_df %>%
    as.data.frame() %>%
    tibble::column_to_rownames("gene_id") %>%
    as.matrix()
}

# ------------------------------------------------------------
# normalize_include_to_tf()
# Normalize many include/exclude styles to uppercase TRUE/FALSE.
# ------------------------------------------------------------
normalize_include_to_tf <- function(x) {
  if (is.logical(x)) {
    return(ifelse(is.na(x), NA_character_, ifelse(x, "TRUE", "FALSE")))
  }

  x0 <- as.character(x)
  x1 <- str_trim(tolower(x0))

  out <- rep(NA_character_, length(x1))
  out[x1 %in% c("true", "t", "1", "yes", "y", "include", "included")] <- "TRUE"
  out[x1 %in% c("false", "f", "0", "no", "n", "exclude", "excluded")] <- "FALSE"
  out
}

# ------------------------------------------------------------
# validate_v0_minimal()
# Minimal contract-oriented validation for V0 outputs.
# ------------------------------------------------------------
validate_v0_minimal <- function(gene_mat, raw_meta, decision_df) {
  if (nrow(gene_mat) == 0 || ncol(gene_mat) == 0) stop2("Expression matrix empty.")
  if (any(is.na(rownames(gene_mat)) | trimws(rownames(gene_mat)) == "")) stop2("gene_id contains NA/empty.")
  if (any(duplicated(rownames(gene_mat)))) stop2("Duplicated gene identifiers after aggregation.")

  # Canonical V0 expression must be a fully numeric, finite matrix before
  # it is handed to V1. This check reports where aggregation still produced
  # NA/NaN/Inf values; it does not silently remove or impute them.
  if (!is.numeric(gene_mat)) {
    stop2("Gene-level expression matrix is not numeric after aggregation.")
  }

  bad_mask <- !is.finite(gene_mat)
  if (any(bad_mask)) {
    bad_idx <- which(bad_mask, arr.ind = TRUE)
    n_bad <- nrow(bad_idx)
    bad_genes <- unique(rownames(gene_mat)[bad_idx[, "row"]])
    bad_samples <- unique(colnames(gene_mat)[bad_idx[, "col"]])

    n_examples <- min(10L, n_bad)
    example_pairs <- paste0(
      rownames(gene_mat)[bad_idx[seq_len(n_examples), "row"]],
      ":",
      colnames(gene_mat)[bad_idx[seq_len(n_examples), "col"]]
    )

    stop2(
      "Gene-level expression contains ", n_bad,
      " non-finite values across ", length(bad_genes),
      " genes and ", length(bad_samples),
      " samples after probe-to-gene aggregation. ",
      "Examples (gene:sample): ", paste(example_pairs, collapse = ", "),
      ". Inspect probe-level missing values and annotation mapping before V1."
    )
  }

  if (!all(c("sample_id", "title", "source_name", "characteristics") %in% names(raw_meta))) {
    stop2("Raw metadata schema invalid.")
  }
  if (any(duplicated(raw_meta$sample_id))) stop2("Duplicated sample_id in raw metadata.")
  if (any(is.na(raw_meta$sample_id) | trimws(raw_meta$sample_id) == "")) stop2("sample_id contains NA/empty in raw metadata.")

  if (!all(c("sample_id", "include", "group_label") %in% names(decision_df))) {
    stop2("Decision schema invalid.")
  }
  if (any(duplicated(decision_df$sample_id))) stop2("Duplicated sample_id in decision.")
  if (!all(decision_df$include %in% c("TRUE", "FALSE"))) stop2("Decision include must be TRUE/FALSE.")

  sample_cols <- colnames(gene_mat)
  if (length(setdiff(sample_cols, raw_meta$sample_id)) > 0) stop2("Expression samples missing in raw metadata.")
  if (length(setdiff(sample_cols, decision_df$sample_id)) > 0) stop2("Expression samples missing in decision.")

  invisible(TRUE)
}

# ------------------------------------------------------------
# write_summary()
#
# Purpose:
#   Human-readable V0 summary text file.
#
# NA-safe:
#   Optional fields are only written when they have real text.
# ------------------------------------------------------------
write_summary <- function(path, info_list) {
  ensure_dir(dirname(path))

  getv <- function(nm, default = "") .as_scalar_string(info_list[[nm]], default = default)

  lines <- c(
    .kv_line("GSE: ", getv("gse")),
    .kv_line("GPL: ", getv("gpl")),
    .kv_line("SeriesMatrix: ", getv("series_matrix")),
    .kv_line("Annotation: ", getv("annotation")),
    .kv_line("AggMethod: ", getv("agg")),
    .kv_line("ForceLog2: ", getv("force_log2")),
    .kv_line("Log2Applied: ", getv("log2_applied")),
    .kv_line("RawProbes: ", getv("n_probe_raw", getv("n_feature_raw"))),
    .kv_line("MappedProbes: ", getv("n_probe_mapped", getv("n_feature_mapped_ok"))),
    .optional_kv_line("MissingValuePolicy: ", getv("missing_value_policy", "")),
    .optional_kv_line("MaxMissingGeneFraction: ", getv("max_missing_gene_fraction", "")),
    .optional_kv_line("GenesBeforeMissingFilter: ", getv("n_gene_before_missing_filter", "")),
    .optional_kv_line("GenesRemovedMissing: ", getv("n_gene_removed_missing", "")),
    .optional_kv_line("RemovedGeneFraction: ", getv("removed_gene_fraction", "")),
    .kv_line("GenesOutput: ", getv("n_gene_out")),
    .kv_line("Samples: ", getv("n_samples")),
    .optional_kv_line("GeneMissingnessReport: ", getv("gene_missingness_report", "")),
    .optional_kv_line("FeatureSpace: ", getv("feature_space", "")),
    .optional_kv_line("V1Eligible: ", getv("v1_eligible", "")),
    .kv_line("Timestamp: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  )

  lines <- lines[!vapply(lines, is.null, logical(1))]
  writeLines(lines, con = path)
}

# ------------------------------------------------------------
# write_manifest()
#
# Purpose:
#   Text manifest for run traceability.
#
# NA-safe:
#   Optional fields are only written when they have real text.
# ------------------------------------------------------------
write_manifest <- function(path, info) {
  ensure_dir(dirname(path))

  getv <- function(nm, default = "") .as_scalar_string(info[[nm]], default = default)

  lines <- c(
    .kv_line("run_id: ", getv("run_id")),
    .kv_line("timestamp: ", getv("timestamp")),
    .kv_line("gse: ", getv("gse")),
    .kv_line("gpl: ", getv("gpl")),
    "",
    "[inputs]",
    .kv_line("series_matrix: ", getv("series_matrix")),
    .kv_line("annotation: ", getv("annotation")),
    .kv_line("decision_metadata: ", getv("decision_path")),
    "",
    "[methods]",
    .kv_line("agg: ", getv("agg")),
    .kv_line("force_log2: ", getv("force_log2")),
    .kv_line("log2_applied: ", getv("log2_applied")),
    .optional_kv_line("feature_space: ", getv("feature_space", "")),
    .optional_kv_line("missing_value_policy: ", getv("missing_value_policy", "")),
    .optional_kv_line("max_missing_gene_fraction: ", getv("max_missing_gene_fraction", "")),
    "",
    "[metrics]",
    .optional_kv_line("raw_probes: ", getv("n_probe_raw", "")),
    .optional_kv_line("mapped_probes: ", getv("n_probe_mapped", "")),
    .optional_kv_line("genes_before_missing_filter: ", getv("n_gene_before_missing_filter", "")),
    .optional_kv_line("genes_removed_missing: ", getv("n_gene_removed_missing", "")),
    .optional_kv_line("removed_gene_fraction: ", getv("removed_gene_fraction", "")),
    .optional_kv_line("genes_output: ", getv("n_gene_out", "")),
    .optional_kv_line("samples: ", getv("n_samples", "")),
    .optional_kv_line("v1_eligible: ", getv("v1_eligible", "")),
    "",
    "[outputs]",
    .kv_line("expression_gene_log: ", getv("expr_out")),
    .kv_line("sample_metadata_raw: ", getv("raw_meta_out")),
    .kv_line("sample_metadata_decision: ", getv("decision_meta_out")),
    .optional_kv_line("gene_missingness_report: ", getv("gene_missingness_report", "")),
    .kv_line("summary: ", getv("summary_out")),
    .kv_line("sessionInfo: ", getv("session_info_out"))
  )

  lines <- lines[!vapply(lines, is.null, logical(1))]
  writeLines(lines, con = path)
}

# ------------------------------------------------------------
# write_session_info()
# Save sessionInfo() for reproducibility/debugging.
# ------------------------------------------------------------
write_session_info <- function(path) {
  ensure_dir(dirname(path))
  si <- capture.output(sessionInfo())
  writeLines(si, con = path)
}
