# ============================================================
# V0_data_ingest/_lib/geo_series_matrix.R
#
# Role:
#   GEO Series Matrix parser for V0 ingest.
#
# Responsibility:
#   1. Read a Series Matrix text file (via shared helper read_text_lines())
#   2. Extract probe x sample expression table
#   3. Parse sample-level raw metadata from !Sample_* header lines
#   4. Parse GPL / platform hints from header lines
#
# Important:
#   - This file is intended to be sourced AFTER v0_io.R
#   - Shared helpers such as stop2() / read_text_lines() live in v0_io.R
# ============================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(tidyr)
})

# ------------------------------------------------------------
# Dependency guard
# ------------------------------------------------------------
if (!exists("stop2", mode = "function")) {
  stop("geo_series_matrix.R requires v0_io.R to be sourced first (missing stop2()).", call. = FALSE)
}
if (!exists("read_text_lines", mode = "function")) {
  stop("geo_series_matrix.R requires v0_io.R to be sourced first (missing read_text_lines()).", call. = FALSE)
}

# ------------------------------------------------------------
# .strip_outer_quotes()
#
# Purpose:
#   Remove one layer of outer single or double quotes from values
#   parsed from GEO header lines.
#
# Why needed:
#   GEO headers sometimes store platform ids like:
#     "GPL6426"
#   If quotes are left in place, downstream filename matching fails.
# ------------------------------------------------------------
.strip_outer_quotes <- function(x) {
  x <- as.character(x)
  x <- str_trim(x)
  x <- str_replace_all(x, '^[\"\']+|[\"\']+$', "")
  x
}

# ------------------------------------------------------------
# read_series_matrix_to_probe_sample()
#
# Purpose:
#   Extract the actual expression table from a GEO Series Matrix file.
#
# Expected structure:
#   ... header ...
#   !series_matrix_table_begin
#   ID_REF   GSMxxx   GSMyyy ...
#   probe1   value    value
#   ...
#   !series_matrix_table_end
#
# Input:
#   lines = full text lines of the Series Matrix file
#
# Output:
#   list(
#     mat = numeric matrix, row = probe/feature, col = sample
#     probe_col = name of the first column in the table
#     sample_names = column names of the expression matrix
#   )
# ------------------------------------------------------------
read_series_matrix_to_probe_sample <- function(lines) {
  begin_idx <- grep("!series_matrix_table_begin", lines, fixed = TRUE)
  end_idx   <- grep("!series_matrix_table_end",   lines, fixed = TRUE)

  if (length(begin_idx) == 0 || length(end_idx) == 0 || begin_idx[1] >= end_idx[1]) {
    stop2("Cannot find '!series_matrix_table_begin'/'_end' in series matrix lines.")
  }

  table_lines <- lines[(begin_idx[1] + 1):(end_idx[1] - 1)]

  df <- suppressMessages(readr::read_tsv(
    I(table_lines),
    show_col_types = FALSE,
    progress = FALSE,
    name_repair = "minimal"
  ))

  if (ncol(df) < 2) stop2("Series matrix table seems too small.")

  probe_col <- colnames(df)[1]

  expr_df <- df
  expr_df[[probe_col]] <- as.character(expr_df[[probe_col]])

  for (j in 2:ncol(expr_df)) {
    expr_df[[j]] <- suppressWarnings(as.numeric(expr_df[[j]]))
  }

  probe_ids <- expr_df[[probe_col]]
  mat <- as.matrix(expr_df[, -1, drop = FALSE])
  rownames(mat) <- probe_ids

  list(
    mat = mat,
    probe_col = probe_col,
    sample_names = colnames(mat)
  )
}

# ------------------------------------------------------------
# parse_sample_metadata_from_series_header()
#
# Purpose:
#   Parse sample-level metadata from the header block before the
#   expression table.
#
# Target fields:
#   - sample_id
#   - title
#   - source_name
#   - characteristics
#
# Design:
#   - If no !Sample_* lines exist, return a minimal NA-filled table
#   - characteristics from repeated lines are concatenated by "; "
# ------------------------------------------------------------
parse_sample_metadata_from_series_header <- function(lines, sample_names) {
  begin_idx <- grep("!series_matrix_table_begin", lines, fixed = TRUE)
  if (length(begin_idx) == 0) {
    stop2("Cannot find !series_matrix_table_begin; cannot parse sample metadata.")
  }

  header_lines <- lines[seq_len(begin_idx[1] - 1)]
  sample_lines <- header_lines[str_detect(header_lines, "^!Sample_")]

  if (length(sample_lines) == 0) {
    return(tibble(
      sample_id = sample_names,
      title = NA_character_,
      source_name = NA_character_,
      characteristics = NA_character_
    ))
  }

  parts_list <- strsplit(sample_lines, "\t", fixed = TRUE)

  long <- lapply(parts_list, function(parts) {
    key <- parts[1]
    vals <- parts[-1]

    n <- min(length(vals), length(sample_names))
    if (n == 0) return(NULL)

    tibble(
      key = key,
      sample_id = sample_names[seq_len(n)],
      value = vals[seq_len(n)]
    )
  }) %>% bind_rows()

  title_df <- long %>%
    filter(key %in% c("!Sample_title")) %>%
    group_by(sample_id) %>%
    summarise(title = first(na_if(value, "")), .groups = "drop")

  source_df <- long %>%
    filter(key %in% c("!Sample_source_name_ch1", "!Sample_source_name")) %>%
    group_by(sample_id) %>%
    summarise(source_name = first(na_if(value, "")), .groups = "drop")

  char_df <- long %>%
    filter(key %in% c("!Sample_characteristics_ch1", "!Sample_characteristics")) %>%
    group_by(sample_id) %>%
    summarise(characteristics = {
      vv <- value
      vv <- vv[!is.na(vv) & vv != ""]
      if (length(vv) == 0) NA_character_ else paste(vv, collapse = "; ")
    }, .groups = "drop")

  tibble(sample_id = sample_names) %>%
    left_join(title_df,  by = "sample_id") %>%
    left_join(source_df, by = "sample_id") %>%
    left_join(char_df,   by = "sample_id")
}

# ------------------------------------------------------------
# extract_gpl_from_series_matrix()
#
# Purpose:
#   Parse platform / GPL hints from Series Matrix header lines.
#
# Output:
#   list(
#     gpl_candidates = preferred GPL candidates for downstream use
#     series_gpl     = GPL values found at series-level
#     sample_gpl_vec = named vector of sample-level GPL (if present)
#   )
#
# Preference:
#   sample-level GPL set > series-level GPL
#
# Important robustness note:
#   GEO sometimes stores GPL ids with outer quotes, e.g. "GPL6426".
#   This function strips those quotes so downstream annotation matching
#   uses clean ids like GPL6426.
# ------------------------------------------------------------
extract_gpl_from_series_matrix <- function(lines, sample_names) {
  begin_idx <- grep("!series_matrix_table_begin", lines, fixed = TRUE)
  if (length(begin_idx) == 0) {
    stop2("Cannot find !series_matrix_table_begin; cannot parse platform ids.")
  }

  header_lines <- lines[seq_len(begin_idx[1] - 1)]

  series_gpl <- header_lines[str_detect(header_lines, "^!Series_platform_id")]
  series_gpl <- unique(str_trim(str_replace(series_gpl, "^!Series_platform_id\\s*", "")))
  series_gpl <- .strip_outer_quotes(series_gpl)
  series_gpl <- series_gpl[nzchar(series_gpl)]

  sample_gpl_lines <- header_lines[str_detect(header_lines, "^!Sample_platform_id")]
  sample_gpl_vec <- NULL

  if (length(sample_gpl_lines) > 0) {
    parts <- strsplit(sample_gpl_lines[1], "\t", fixed = TRUE)[[1]]
    vals <- parts[-1]

    n <- min(length(vals), length(sample_names))
    if (n > 0) {
      sample_gpl_vec <- str_trim(vals[seq_len(n)])
      sample_gpl_vec <- .strip_outer_quotes(sample_gpl_vec)
      sample_gpl_vec <- ifelse(sample_gpl_vec == "", NA_character_, sample_gpl_vec)
      names(sample_gpl_vec) <- sample_names[seq_len(n)]
    }
  }

  sample_gpl_set <- if (!is.null(sample_gpl_vec)) unique(na.omit(sample_gpl_vec)) else character(0)
  gpl_candidates <- if (length(sample_gpl_set) > 0) sample_gpl_set else series_gpl
  gpl_candidates <- unique(gpl_candidates)

  list(
    gpl_candidates = gpl_candidates,
    series_gpl = series_gpl,
    sample_gpl_vec = sample_gpl_vec
  )
}
