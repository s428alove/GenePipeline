# ============================================================
# V0_data_ingest/_lib/pre_qc.R
#
# Role:
#   Pre-QC helper module for V0 ingest.
#
# Purpose:
#   Run lightweight, probe-level quality prechecks before downstream
#   transformation and analysis.
#
# Design goals:
#   1. Stay lightweight and deterministic
#   2. Do not auto-exclude samples
#   3. Produce human-reviewable metrics + flags + summary
#   4. Support interpretation as a suggestion layer
#   5. Support before-vs-after log2 comparison reporting
#   6. Expose a single "formal" pre-QC entry point for V0:
#        run_preqc_before_after_log2()
#
# Recommended placement in V0 flow:
#   read series matrix
#     -> build probe-level expression matrix
#     -> run pre-QC before log2
#     -> apply log2(x + 1)
#     -> run pre-QC after log2
#     -> write before/after/comparison/interpretation reports
#     -> continue to annotation + probe->gene aggregation
#
# Dependencies:
#   - Intended to be sourced AFTER v0_io.R
#   - Uses stop2(), ensure_dir() from v0_io.R
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(tibble)
  library(stringr)
})

# ------------------------------------------------------------
# Dependency guard
# ------------------------------------------------------------
for (.fn in c("stop2", "ensure_dir")) {
  if (!exists(.fn, mode = "function")) {
    stop("pre_qc.R requires v0_io.R to be sourced first (missing ", .fn, "()).", call. = FALSE)
  }
}
rm(.fn)

# ------------------------------------------------------------
# .safe_numeric_matrix()
# ------------------------------------------------------------
.safe_numeric_matrix <- function(expr_mat) {
  if (is.null(expr_mat) || length(expr_mat) == 0) {
    stop2("pre-QC input expression matrix is empty.")
  }

  mat <- as.matrix(expr_mat)

  if (nrow(mat) == 0 || ncol(mat) == 0) {
    stop2("pre-QC input expression matrix has zero rows or columns.")
  }

  if (is.null(colnames(mat)) || any(is.na(colnames(mat)) | trimws(colnames(mat)) == "")) {
    stop2("pre-QC input expression matrix is missing valid sample column names.")
  }

  suppressWarnings(storage.mode(mat) <- "numeric")
  mat
}

# ------------------------------------------------------------
# .robust_z()
#
# Purpose:
#   Median/MAD-based robust z-score.
# ------------------------------------------------------------
.robust_z <- function(x) {
  x <- as.numeric(x)
  med <- stats::median(x, na.rm = TRUE)
  mad0 <- stats::mad(x, center = med, constant = 1, na.rm = TRUE)

  if (!is.finite(mad0) || mad0 == 0) {
    return(rep(0, length(x)))
  }

  (x - med) / mad0
}

# ------------------------------------------------------------
# compute_dataset_basic_metrics()
# ------------------------------------------------------------
compute_dataset_basic_metrics <- function(expr_mat) {
  mat <- .safe_numeric_matrix(expr_mat)

  vals <- as.numeric(mat)
  vals_finite <- vals[is.finite(vals)]

  tibble(
    n_features = nrow(mat),
    n_samples = ncol(mat),
    n_total_values = length(vals),
    n_finite_values = length(vals_finite),
    na_rate = mean(!is.finite(vals)),
    min_value = if (length(vals_finite) > 0) min(vals_finite) else NA_real_,
    median_value = if (length(vals_finite) > 0) stats::median(vals_finite) else NA_real_,
    max_value = if (length(vals_finite) > 0) max(vals_finite) else NA_real_
  )
}

# ------------------------------------------------------------
# compute_sample_basic_metrics()
# ------------------------------------------------------------
compute_sample_basic_metrics <- function(expr_mat) {
  mat <- .safe_numeric_matrix(expr_mat)

  metrics_list <- lapply(seq_len(ncol(mat)), function(j) {
    x <- suppressWarnings(as.numeric(mat[, j]))
    finite_x <- x[is.finite(x)]

    tibble(
      sample_id = colnames(mat)[j],
      n_features = nrow(mat),
      n_finite = length(finite_x),
      na_rate = mean(!is.finite(x)),
      min_value = if (length(finite_x) > 0) min(finite_x) else NA_real_,
      q1_value = if (length(finite_x) > 0) as.numeric(stats::quantile(finite_x, probs = 0.25, na.rm = TRUE, names = FALSE)) else NA_real_,
      median_value = if (length(finite_x) > 0) stats::median(finite_x) else NA_real_,
      mean_value = if (length(finite_x) > 0) mean(finite_x) else NA_real_,
      q3_value = if (length(finite_x) > 0) as.numeric(stats::quantile(finite_x, probs = 0.75, na.rm = TRUE, names = FALSE)) else NA_real_,
      max_value = if (length(finite_x) > 0) max(finite_x) else NA_real_,
      sd_value = if (length(finite_x) > 1) stats::sd(finite_x) else NA_real_,
      iqr_value = if (length(finite_x) > 0) stats::IQR(finite_x, na.rm = TRUE) else NA_real_
    )
  })

  bind_rows(metrics_list)
}

# ------------------------------------------------------------
# compute_sample_cor_metrics()
# ------------------------------------------------------------
compute_sample_cor_metrics <- function(expr_mat, method = "pearson") {
  mat <- .safe_numeric_matrix(expr_mat)

  if (ncol(mat) == 1) {
    return(tibble(
      sample_id = colnames(mat),
      cor_n_others = 0L,
      cor_mean = NA_real_,
      cor_median = NA_real_,
      cor_min = NA_real_,
      cor_max = NA_real_
    ))
  }

  cor_mat <- suppressWarnings(stats::cor(
    mat,
    use = "pairwise.complete.obs",
    method = method
  ))

  out <- lapply(seq_len(ncol(cor_mat)), function(j) {
    v <- cor_mat[, j]
    v <- v[names(v) != colnames(cor_mat)[j]]
    v_finite <- v[is.finite(v)]

    tibble(
      sample_id = colnames(cor_mat)[j],
      cor_n_others = length(v_finite),
      cor_mean = if (length(v_finite) > 0) mean(v_finite) else NA_real_,
      cor_median = if (length(v_finite) > 0) stats::median(v_finite) else NA_real_,
      cor_min = if (length(v_finite) > 0) min(v_finite) else NA_real_,
      cor_max = if (length(v_finite) > 0) max(v_finite) else NA_real_
    )
  })

  bind_rows(out)
}

# ------------------------------------------------------------
# flag_preqc_samples()
#
# Purpose:
#   Convert sample metrics into lightweight review flags.
#
# Important:
#   These are review hints only.
#   They must not directly auto-exclude samples.
# ------------------------------------------------------------
flag_preqc_samples <- function(
  metrics_df,
  na_rate_cutoff = 0.05,
  cor_median_cutoff = 0.90,
  median_abs_robust_z_cutoff = 3,
  iqr_abs_robust_z_cutoff = 3
) {
  required_cols <- c("sample_id", "na_rate", "median_value", "iqr_value", "cor_median")
  missing_cols <- setdiff(required_cols, names(metrics_df))
  if (length(missing_cols) > 0) {
    stop2("flag_preqc_samples(): missing required columns: ", paste(missing_cols, collapse = ", "))
  }

  out <- metrics_df %>%
    mutate(
      median_robust_z = .robust_z(median_value),
      iqr_robust_z = .robust_z(iqr_value),
      flag_high_na = !is.na(na_rate) & na_rate > na_rate_cutoff,
      flag_low_corr = !is.na(cor_median) & cor_median < cor_median_cutoff,
      flag_extreme_median = !is.na(median_robust_z) & abs(median_robust_z) > median_abs_robust_z_cutoff,
      flag_extreme_iqr = !is.na(iqr_robust_z) & abs(iqr_robust_z) > iqr_abs_robust_z_cutoff
    ) %>%
    rowwise() %>%
    mutate(
      preqc_flag_any = any(c(flag_high_na, flag_low_corr, flag_extreme_median, flag_extreme_iqr), na.rm = TRUE),
      preqc_note = paste(
        c(
          if (isTRUE(flag_high_na)) paste0("high_na_rate>", na_rate_cutoff) else NULL,
          if (isTRUE(flag_low_corr)) paste0("low_median_cor<", cor_median_cutoff) else NULL,
          if (isTRUE(flag_extreme_median)) paste0("extreme_median_robust_z=", round(median_robust_z, 3)) else NULL,
          if (isTRUE(flag_extreme_iqr)) paste0("extreme_iqr_robust_z=", round(iqr_robust_z, 3)) else NULL
        ),
        collapse = "; "
      )
    ) %>%
    ungroup()

  out %>%
    mutate(preqc_note = if_else(preqc_note == "", NA_character_, preqc_note))
}

# ------------------------------------------------------------
# suggest_log2_from_dataset_metrics()
# ------------------------------------------------------------
suggest_log2_from_dataset_metrics <- function(dataset_metrics_df) {
  if (nrow(dataset_metrics_df) != 1) {
    stop2("suggest_log2_from_dataset_metrics(): dataset_metrics_df must have exactly 1 row.")
  }

  mx <- dataset_metrics_df$max_value[[1]]
  mn <- dataset_metrics_df$min_value[[1]]

  suspected <- FALSE
  reason <- "no_strong_signal"

  if (is.finite(mn) && mn < 0) {
    suspected <- FALSE
    reason <- "negative_values_present_likely_already_logged"
  } else if (is.finite(mx) && mx > 50) {
    suspected <- TRUE
    reason <- "max_value_gt_50_suspect_linear_scale"
  }

  tibble(
    log2_suspected_needed = suspected,
    log2_suggestion_reason = reason
  )
}

# ------------------------------------------------------------
# interpret_preqc()
#
# Purpose:
#   Generate human-readable interpretation for one pre-QC run.
#
# Core principle:
#   Distinguish global structure problems from individual outliers.
# ------------------------------------------------------------
interpret_preqc <- function(dataset_metrics_df, sample_flags_df, log2_suggestion_df) {
  if (nrow(dataset_metrics_df) != 1) {
    stop2("interpret_preqc(): dataset_metrics_df must have exactly 1 row.")
  }

  n_samples <- dataset_metrics_df$n_samples[[1]]
  flagged_ids <- sample_flags_df %>%
    filter(preqc_flag_any) %>%
    pull(sample_id)

  flag_ratio <- if (n_samples > 0) length(flagged_ids) / n_samples else NA_real_
  lines <- character(0)

  if (isTRUE(log2_suggestion_df$log2_suspected_needed[[1]])) {
    lines <- c(
      lines,
      paste0(
        "Likely not log-transformed (",
        log2_suggestion_df$log2_suggestion_reason[[1]],
        ")"
      )
    )
  }

  if (!is.na(flag_ratio) && flag_ratio > 0.80) {
    lines <- c(lines, "Most samples flagged -> global structure issue suspected (scale/normalization more likely than individual sample failure)")
  } else if (length(flagged_ids) > 0) {
    lines <- c(lines, paste0("Potential individual outlier samples detected: ", paste(flagged_ids, collapse = ", ")))
  } else {
    lines <- c(lines, "No clear individual outliers detected")
  }

  high_na_ids <- sample_flags_df %>%
    filter(flag_high_na) %>%
    pull(sample_id)

  if (length(high_na_ids) > 0) {
    lines <- c(lines, paste0("Samples with high missing rate: ", paste(high_na_ids, collapse = ", ")))
  }

  extreme_median_ids <- sample_flags_df %>%
    filter(flag_extreme_median) %>%
    pull(sample_id)

  if (length(extreme_median_ids) > 0 && length(extreme_median_ids) < n_samples) {
    lines <- c(lines, paste0("Samples with abnormal median distribution: ", paste(extreme_median_ids, collapse = ", ")))
  }

  extreme_iqr_ids <- sample_flags_df %>%
    filter(flag_extreme_iqr) %>%
    pull(sample_id)

  if (length(extreme_iqr_ids) > 0 && length(extreme_iqr_ids) < n_samples) {
    lines <- c(lines, paste0("Samples with abnormal spread/IQR: ", paste(extreme_iqr_ids, collapse = ", ")))
  }

  tibble(interpretation_line = lines)
}

# ------------------------------------------------------------
# build_preqc_summary_lines()
# ------------------------------------------------------------
build_preqc_summary_lines <- function(dataset_metrics_df, flags_df, log2_suggestion_df, interpretation_df = NULL) {
  flagged_ids <- flags_df %>%
    filter(preqc_flag_any) %>%
    pull(sample_id)

  lines <- c(
    "=== Pre-QC Summary ===",
    paste0("Samples: ", dataset_metrics_df$n_samples[[1]]),
    paste0("Features: ", dataset_metrics_df$n_features[[1]]),
    paste0("NA rate (overall): ", signif(dataset_metrics_df$na_rate[[1]], 4)),
    paste0("Value range: ", signif(dataset_metrics_df$min_value[[1]], 5), " to ", signif(dataset_metrics_df$max_value[[1]], 5)),
    paste0("Median value: ", signif(dataset_metrics_df$median_value[[1]], 5)),
    paste0("Flagged samples: ", length(flagged_ids)),
    paste0("Flagged sample IDs: ", if (length(flagged_ids) > 0) paste(flagged_ids, collapse = ", ") else "<none>"),
    paste0(
      "Log2 suspected needed: ",
      as.character(log2_suggestion_df$log2_suspected_needed[[1]]),
      " (", log2_suggestion_df$log2_suggestion_reason[[1]], ")"
    )
  )

  if (!is.null(interpretation_df) && nrow(interpretation_df) > 0) {
    lines <- c(
      lines,
      "",
      "=== Interpretation ===",
      paste0("- ", interpretation_df$interpretation_line)
    )
  }

  lines
}

# ------------------------------------------------------------
# write_preqc_outputs()
#
# Files:
#   - preqc_dataset_metrics.tsv
#   - preqc_sample_metrics.tsv
#   - preqc_sample_flags.tsv
#   - preqc_summary.txt
# ------------------------------------------------------------
write_preqc_outputs <- function(
  out_dir,
  dataset_metrics_df,
  sample_metrics_df,
  flags_df,
  log2_suggestion_df,
  interpretation_df = NULL
) {
  ensure_dir(out_dir)

  dataset_out <- file.path(out_dir, "preqc_dataset_metrics.tsv")
  metrics_out <- file.path(out_dir, "preqc_sample_metrics.tsv")
  flags_out   <- file.path(out_dir, "preqc_sample_flags.tsv")
  summary_out <- file.path(out_dir, "preqc_summary.txt")

  dataset_full <- bind_cols(dataset_metrics_df, log2_suggestion_df)

  write_tsv(dataset_full, dataset_out)
  write_tsv(sample_metrics_df, metrics_out)
  write_tsv(flags_df, flags_out)
  writeLines(
    build_preqc_summary_lines(dataset_metrics_df, flags_df, log2_suggestion_df, interpretation_df),
    con = summary_out
  )

  list(
    dataset_out = dataset_out,
    metrics_out = metrics_out,
    flags_out = flags_out,
    summary_out = summary_out
  )
}

# ------------------------------------------------------------
# run_preqc_probe_level()
#
# Purpose:
#   Single-matrix pre-QC runner.
#
# Note:
#   This remains useful as a building block, but V0 should prefer
#   run_preqc_before_after_log2() as the formal entry point.
# ------------------------------------------------------------
run_preqc_probe_level <- function(
  expr_mat,
  out_dir = NULL,
  cor_method = "pearson",
  na_rate_cutoff = 0.05,
  cor_median_cutoff = 0.90,
  median_abs_robust_z_cutoff = 3,
  iqr_abs_robust_z_cutoff = 3,
  write_outputs = TRUE
) {
  mat <- .safe_numeric_matrix(expr_mat)

  dataset_metrics <- compute_dataset_basic_metrics(mat)
  sample_basic <- compute_sample_basic_metrics(mat)
  sample_cor <- compute_sample_cor_metrics(mat, method = cor_method)

  sample_metrics <- sample_basic %>%
    left_join(sample_cor, by = "sample_id")

  sample_flags <- flag_preqc_samples(
    metrics_df = sample_metrics,
    na_rate_cutoff = na_rate_cutoff,
    cor_median_cutoff = cor_median_cutoff,
    median_abs_robust_z_cutoff = median_abs_robust_z_cutoff,
    iqr_abs_robust_z_cutoff = iqr_abs_robust_z_cutoff
  )

  log2_suggestion <- suggest_log2_from_dataset_metrics(dataset_metrics)

  interpretation <- interpret_preqc(
    dataset_metrics_df = dataset_metrics,
    sample_flags_df = sample_flags,
    log2_suggestion_df = log2_suggestion
  )

  output_paths <- NULL
  if (isTRUE(write_outputs)) {
    if (is.null(out_dir) || is.na(out_dir) || !nzchar(out_dir)) {
      stop2("run_preqc_probe_level(): out_dir must be provided when write_outputs=TRUE.")
    }

    output_paths <- write_preqc_outputs(
      out_dir = out_dir,
      dataset_metrics_df = dataset_metrics,
      sample_metrics_df = sample_metrics,
      flags_df = sample_flags,
      log2_suggestion_df = log2_suggestion,
      interpretation_df = interpretation
    )
  }

  list(
    dataset_metrics = dataset_metrics,
    sample_metrics = sample_metrics,
    sample_flags = sample_flags,
    log2_suggestion = log2_suggestion,
    interpretation = interpretation,
    output_paths = output_paths
  )
}

# ------------------------------------------------------------
# compare_preqc_runs()
# ------------------------------------------------------------
compare_preqc_runs <- function(pre_before, pre_after) {
  before_flags <- pre_before$sample_flags
  after_flags  <- pre_after$sample_flags

  before_flagged_ids <- before_flags %>%
    filter(preqc_flag_any) %>%
    pull(sample_id)

  after_flagged_ids <- after_flags %>%
    filter(preqc_flag_any) %>%
    pull(sample_id)

  comp_df <- tibble(
    n_samples_before = pre_before$dataset_metrics$n_samples[[1]],
    n_samples_after = pre_after$dataset_metrics$n_samples[[1]],
    n_features_before = pre_before$dataset_metrics$n_features[[1]],
    n_features_after = pre_after$dataset_metrics$n_features[[1]],
    na_rate_before = pre_before$dataset_metrics$na_rate[[1]],
    na_rate_after = pre_after$dataset_metrics$na_rate[[1]],
    median_value_before = pre_before$dataset_metrics$median_value[[1]],
    median_value_after = pre_after$dataset_metrics$median_value[[1]],
    max_value_before = pre_before$dataset_metrics$max_value[[1]],
    max_value_after = pre_after$dataset_metrics$max_value[[1]],
    flagged_samples_before = length(before_flagged_ids),
    flagged_samples_after = length(after_flagged_ids),
    low_corr_samples_before = sum(before_flags$flag_low_corr, na.rm = TRUE),
    low_corr_samples_after = sum(after_flags$flag_low_corr, na.rm = TRUE)
  )

  list(
    comparison_table = comp_df,
    before_flagged_ids = before_flagged_ids,
    after_flagged_ids = after_flagged_ids
  )
}

# ------------------------------------------------------------
# build_preqc_comparison_lines()
# ------------------------------------------------------------
build_preqc_comparison_lines <- function(pre_before, pre_after) {
  cmp <- compare_preqc_runs(pre_before, pre_after)
  comp <- cmp$comparison_table

  before_flagged_ids <- cmp$before_flagged_ids
  after_flagged_ids  <- cmp$after_flagged_ids

  lines <- c(
    "=== Pre-QC Comparison (Before vs After log2) ===",
    "",
    "---- Dataset scale ----",
    paste0("Before median value: ", signif(comp$median_value_before[[1]], 5)),
    paste0("After  median value: ", signif(comp$median_value_after[[1]], 5)),
    paste0("Before max value: ", signif(comp$max_value_before[[1]], 5)),
    paste0("After  max value: ", signif(comp$max_value_after[[1]], 5)),
    "",
    "---- Flags ----",
    paste0("Before flagged samples: ", comp$flagged_samples_before[[1]]),
    paste0("After  flagged samples: ", comp$flagged_samples_after[[1]]),
    paste0("Before low-correlation samples: ", comp$low_corr_samples_before[[1]]),
    paste0("After  low-correlation samples: ", comp$low_corr_samples_after[[1]]),
    "",
    "---- Interpretation ----"
  )

  if (length(before_flagged_ids) > 0.8 * comp$n_samples_before[[1]]) {
    lines <- c(lines, "- Before log2: global structure issue suspected (scale problem more likely than individual sample failure)")
  } else if (length(before_flagged_ids) > 0) {
    lines <- c(lines, paste0("- Before log2 flagged samples: ", paste(before_flagged_ids, collapse = ", ")))
  } else {
    lines <- c(lines, "- Before log2: no clear individual outliers detected")
  }

  if (length(after_flagged_ids) == 0) {
    lines <- c(lines, "- After log2: no clear individual outliers detected")
  } else {
    lines <- c(lines, paste0("- After log2 potential outlier samples: ", paste(after_flagged_ids, collapse = ", ")))
  }

  if (isTRUE(pre_before$log2_suggestion$log2_suspected_needed[[1]]) && !isTRUE(pre_after$log2_suggestion$log2_suspected_needed[[1]])) {
    lines <- c(lines, "- Log2 transformation appears to have improved scale consistency")
  }

  lines
}

# ------------------------------------------------------------
# build_preqc_interpretation_summary_lines()
#
# Purpose:
#   Produce one final, integrated interpretation summary for the
#   whole pre-QC process.
#
# This is the human-facing summary that should be read first.
# ------------------------------------------------------------
build_preqc_interpretation_summary_lines <- function(pre_before, pre_after) {
  cmp <- compare_preqc_runs(pre_before, pre_after)
  comp <- cmp$comparison_table
  after_flagged_ids <- cmp$after_flagged_ids

  lines <- c(
    "=== Pre-QC Interpretation Summary ===",
    "",
    "1. Scale assessment"
  )

  if (isTRUE(pre_before$log2_suggestion$log2_suspected_needed[[1]])) {
    lines <- c(lines, "- Raw probe-level matrix likely was not log-transformed before preprocessing.")
  } else {
    lines <- c(lines, "- Raw probe-level matrix did not show a strong signal of requiring log2 transformation.")
  }

  if (comp$max_value_after[[1]] < comp$max_value_before[[1]]) {
    lines <- c(lines, "- After log2 transformation, expression scale became more compressed and stable.")
  }

  lines <- c(
    lines,
    "",
    "2. Global structure"
  )

  if (comp$flagged_samples_before[[1]] > 0.8 * comp$n_samples_before[[1]]) {
    lines <- c(lines, "- Before log2, most samples were flagged, suggesting a dataset-wide scale/structure issue rather than isolated sample failure.")
  } else if (comp$flagged_samples_before[[1]] > 0) {
    lines <- c(lines, "- Before log2, only a subset of samples were flagged.")
  } else {
    lines <- c(lines, "- Before log2, no clear broad pre-QC burden was detected.")
  }

  if (comp$flagged_samples_after[[1]] < comp$flagged_samples_before[[1]]) {
    lines <- c(lines, "- After log2, the overall pre-QC flag burden decreased.")
  } else if (comp$flagged_samples_after[[1]] == comp$flagged_samples_before[[1]]) {
    lines <- c(lines, "- After log2, the pre-QC flag burden did not materially change.")
  } else {
    lines <- c(lines, "- After log2, more samples were flagged; the transformed matrix should be reviewed carefully.")
  }

  lines <- c(
    lines,
    "",
    "3. Individual outlier review"
  )

  if (length(after_flagged_ids) == 0) {
    lines <- c(lines, "- No clear individual outliers remained after log2 transformation.")
  } else {
    lines <- c(lines, paste0("- Potential outlier samples after log2: ", paste(after_flagged_ids, collapse = ", ")))
    lines <- c(lines, "- These samples should be reviewed manually before any downstream exclusion decision.")
  }

  lines <- c(
    lines,
    "",
    "4. Recommendation",
    "- Use after-log2 pre-QC flags as review hints in decision metadata.",
    "- Do not auto-exclude samples solely based on pre-QC flags."
  )

  lines
}

# ------------------------------------------------------------
# write_preqc_comparison()
#
# Files:
#   - preqc_comparison.tsv
#   - preqc_comparison.txt
#   - preqc_interpretation_summary.txt
# ------------------------------------------------------------
write_preqc_comparison <- function(out_dir, pre_before, pre_after) {
  ensure_dir(out_dir)

  cmp <- compare_preqc_runs(pre_before, pre_after)
  tsv_out <- file.path(out_dir, "preqc_comparison.tsv")
  txt_out <- file.path(out_dir, "preqc_comparison.txt")
  interpretation_out <- file.path(out_dir, "preqc_interpretation_summary.txt")

  write_tsv(cmp$comparison_table, tsv_out)
  writeLines(build_preqc_comparison_lines(pre_before, pre_after), con = txt_out)
  writeLines(build_preqc_interpretation_summary_lines(pre_before, pre_after), con = interpretation_out)

  list(
    comparison_tsv = tsv_out,
    comparison_txt = txt_out,
    interpretation_summary_txt = interpretation_out
  )
}

# ------------------------------------------------------------
# run_preqc_before_after_log2()
#
# Purpose:
#   Formal V0 pre-QC entry point.
#
# Folder layout produced:
#   _engineering/
#     preqc_before/
#       preqc_dataset_metrics.tsv
#       preqc_sample_metrics.tsv
#       preqc_sample_flags.tsv
#       preqc_summary.txt
#     preqc_after/
#       preqc_dataset_metrics.tsv
#       preqc_sample_metrics.tsv
#       preqc_sample_flags.tsv
#       preqc_summary.txt
#     preqc_comparison.tsv
#     preqc_comparison.txt
#     preqc_interpretation_summary.txt
#
# Return:
#   list(
#     before = ...,
#     after = ...,
#     comparison_paths = ...
#   )
# ------------------------------------------------------------
run_preqc_before_after_log2 <- function(
  expr_mat,
  out_dir,
  cor_method = "pearson",
  na_rate_cutoff = 0.05,
  cor_median_cutoff = 0.90,
  median_abs_robust_z_cutoff = 3,
  iqr_abs_robust_z_cutoff = 3
) {
  mat <- .safe_numeric_matrix(expr_mat)
  ensure_dir(out_dir)

  before_dir <- file.path(out_dir, "preqc_before")
  after_dir  <- file.path(out_dir, "preqc_after")

  pre_before <- run_preqc_probe_level(
    expr_mat = mat,
    out_dir = before_dir,
    cor_method = cor_method,
    na_rate_cutoff = na_rate_cutoff,
    cor_median_cutoff = cor_median_cutoff,
    median_abs_robust_z_cutoff = median_abs_robust_z_cutoff,
    iqr_abs_robust_z_cutoff = iqr_abs_robust_z_cutoff,
    write_outputs = TRUE
  )

  mat_log2 <- log2(mat + 1)

  pre_after <- run_preqc_probe_level(
    expr_mat = mat_log2,
    out_dir = after_dir,
    cor_method = cor_method,
    na_rate_cutoff = na_rate_cutoff,
    cor_median_cutoff = cor_median_cutoff,
    median_abs_robust_z_cutoff = median_abs_robust_z_cutoff,
    iqr_abs_robust_z_cutoff = iqr_abs_robust_z_cutoff,
    write_outputs = TRUE
  )

  comparison_paths <- write_preqc_comparison(
    out_dir = out_dir,
    pre_before = pre_before,
    pre_after = pre_after
  )

  list(
    before = pre_before,
    after = pre_after,
    comparison_paths = comparison_paths
  )
}
