# V1_analysis/scripts/_lib/validate_inputs.R
# ============================================================
# validate_v1_inputs()
# - Read canonical V0/V1 inputs:
#     data_processed/<GSE>/expression_gene_log.tsv
#     data_processed/<GSE>/sample_metadata_merged.tsv
# - Return aligned objects for modules:
#     expr_mat_included: gene x included_samples (numeric matrix)
#     meta_included_aligned: included meta rows aligned to expr columns
#
# Supports expression formats:
#   (A) New V0 (recommended):
#       gene_id, feature_ids, n_features, <samples...>
#   (B) Old:
#       gene_id, <samples...>
# ============================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
})

stop2 <- function(...) stop(paste0(..., collapse=""), call. = FALSE)

read_tsv_header_only <- function(path) {
  hdr <- readLines(path, n = 1, warn = FALSE)
  if (length(hdr) == 0) stop2("Cannot read header from: ", path)
  strsplit(hdr, "\t", fixed = TRUE)[[1]]
}

infer_expr_sample_cols <- function(header_vec) {
  if (length(header_vec) < 2) return(character(0))
  
  # Preferred: new V0 format
  if (length(header_vec) >= 3 &&
      header_vec[1] == "gene_id" &&
      header_vec[2] == "feature_ids" &&
      header_vec[3] == "n_features") {
    return(header_vec[-c(1,2,3)])
  }
  
  # Backward compatible: old format
  if (header_vec[1] == "gene_id") {
    return(header_vec[-1])
  }
  
  # Fallback: treat everything except first column as samples
  header_vec[-1]
}

read_expression_gene_log <- function(expr_path) {
  if (!file.exists(expr_path)) stop2("Not found: ", expr_path)
  
  hdr <- read_tsv_header_only(expr_path)
  sample_cols <- infer_expr_sample_cols(hdr)
  if (length(sample_cols) == 0) stop2("Cannot infer expression sample columns from header: ", expr_path)
  
  # Choose columns to read: gene_id + optional trace cols + samples
  # We'll read everything then drop trace cols, because read_tsv col_select by name can fail if duplicates.
  df <- readr::read_tsv(expr_path, show_col_types = FALSE)
  
  if (!("gene_id" %in% names(df))) stop2("Expression missing gene_id column: ", expr_path)
  
  # Keep only gene_id + sample columns (ignore feature_ids/n_features if present)
  keep <- c("gene_id", intersect(sample_cols, names(df)))
  if (length(keep) < 2) {
    stop2("Expression has no sample columns after parsing header. File: ", expr_path)
  }
  df2 <- df %>% dplyr::select(all_of(keep))
  
  # Build matrix gene x sample
  gene_id <- as.character(df2$gene_id)
  df2$gene_id <- NULL
  
  # Convert to numeric matrix. Fail fast if conversion creates NA values,
  # because V1 modules require numeric gene-level expression values.
  mat <- as.matrix(df2)
  suppressWarnings(storage.mode(mat) <- "numeric")

  if (anyNA(mat)) {
    na_pos <- which(is.na(mat), arr.ind = TRUE)
    bad_rows <- gene_id[head(na_pos[, "row"], 10)]
    bad_cols <- colnames(mat)[head(na_pos[, "col"], 10)]
    bad_pairs <- paste0(bad_rows, ":", bad_cols)
    stop2(
      "Expression matrix contains NA after numeric conversion. ",
      "Check non-numeric or missing values. Examples (up to 10 gene:sample): ",
      paste(bad_pairs, collapse = ", ")
    )
  }
  
  if (anyNA(gene_id) || any(trimws(gene_id) == "")) stop2("Expression gene_id has NA/empty.")
  if (any(duplicated(gene_id))) stop2("Expression gene_id duplicated (expected unique).")
  rownames(mat) <- gene_id
  
  list(mat = mat, sample_ids = colnames(mat), n_gene = nrow(mat), n_sample = ncol(mat))
}

read_merged_meta <- function(meta_path) {
  if (!file.exists(meta_path)) stop2("Not found: ", meta_path)
  meta <- readr::read_tsv(meta_path, show_col_types = FALSE)
  
  # required columns
  req <- c("sample_id", "include", "group_label")
  miss <- setdiff(req, names(meta))
  if (length(miss) > 0) stop2("Merged metadata missing columns: ", paste(miss, collapse=", "), " | File: ", meta_path)
  
  meta <- meta %>% mutate(
    sample_id = as.character(sample_id),
    include = as.character(include)
  )
  
  if (any(is.na(meta$sample_id) | trimws(meta$sample_id) == "")) stop2("Merged meta has NA/empty sample_id.")
  if (any(duplicated(meta$sample_id))) stop2("Merged meta has duplicated sample_id.")
  
  # enforce include TRUE/FALSE
  bad_inc <- !(meta$include %in% c("TRUE","FALSE"))
  if (any(bad_inc)) {
    stop2("Merged meta include must be TRUE/FALSE. Bad sample_id (up to 10): ",
          paste(head(meta$sample_id[bad_inc], 10), collapse=", "))
  }
  
  meta
}

validate_v1_inputs <- function(expr_path, meta_path, two_group_required = TRUE) {
  expr <- read_expression_gene_log(expr_path)
  meta <- read_merged_meta(meta_path)
  
  # Ensure expression sample columns exist in meta
  miss_meta <- setdiff(expr$sample_ids, meta$sample_id)
  if (length(miss_meta) > 0) {
    stop2(
      "Alignment invalid: expression sample columns not found in meta sample_id (up to 10): ",
      paste(head(miss_meta, 10), collapse=", ")
    )
  }
  
  # Keep included samples only
  meta_inc <- meta %>% filter(include == "TRUE")
  if (nrow(meta_inc) == 0) stop2("No included samples (include==TRUE) in merged meta: ", meta_path)
  
  # require group_label for included
  bad_grp <- meta_inc$sample_id[is.na(meta_inc$group_label) | trimws(as.character(meta_inc$group_label)) == ""]
  if (length(bad_grp) > 0) {
    stop2("Included samples missing group_label (up to 10): ", paste(head(bad_grp, 10), collapse=", "))
  }
  
  # Ensure included metadata samples exist in expression.
  # This reverse-direction check gives a clear error before subsetting.
  miss_expr <- setdiff(meta_inc$sample_id, expr$sample_ids)
  if (length(miss_expr) > 0) {
    stop2(
      "Alignment invalid: included meta sample_id not found in expression columns (up to 10): ",
      paste(head(miss_expr, 10), collapse = ", ")
    )
  }

  group_counts <- table(as.character(meta_inc$group_label))

  if (isTRUE(two_group_required)) {
    n_groups <- length(group_counts)
    if (n_groups != 2) {
      stop2(
        "two_group_required=TRUE requires exactly 2 groups among included samples. Found: ",
        n_groups,
        " | Groups: ",
        paste(names(group_counts), collapse = ", ")
      )
    }
  }

  bad_small_groups <- names(group_counts[group_counts < 2])
  if (length(bad_small_groups) > 0) {
    stop2(
      "Each group must have >=2 included samples. Bad group(s): ",
      paste(bad_small_groups, collapse = ", ")
    )
  }
  
  # Align order: meta rows and expr columns
  keep_samples <- meta_inc$sample_id
  expr_mat_inc <- expr$mat[, keep_samples, drop = FALSE]
  meta_inc_aligned <- meta_inc[match(colnames(expr_mat_inc), meta_inc$sample_id), , drop = FALSE]
  
  if (any(is.na(meta_inc_aligned$sample_id))) stop2("Alignment error after matching included samples.")
  
  list(
    expr_mat_included = expr_mat_inc,
    meta_included_aligned = meta_inc_aligned,
    expr_info = list(n_genes = expr$n_gene, n_samples_total = expr$n_sample),
    meta_info = list(n_meta_total = nrow(meta), n_meta_included = nrow(meta_inc)),
    group_info = list(
      group_levels = names(group_counts),
      group_counts = as.list(as.integer(group_counts))
    )
  )
}
