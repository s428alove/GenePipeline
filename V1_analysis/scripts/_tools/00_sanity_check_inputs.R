#!/usr/bin/env Rscript
# 00_sanity_check_inputs.R
# V1 preflight for GenePipeline.
#
# Location:
#   V1_analysis/scripts/_tools/00_sanity_check_inputs.R
#
# Responsibilities:
#   1. Verify all packages required by the V1 core are installed.
#   2. Validate canonical expression and merged metadata inputs.
#   3. Validate V1 threshold arguments.
#   4. When DEG is planned, validate two-group and case/control readiness.
#
# This script does not modify data or produce analysis results.

# One dependency definition and one repository package readiness check.
source("tools/r-environment-lib.R")
gp_require_ready(getwd())
required_packages <- gp_definition(getwd())$direct

suppressPackageStartupMessages({
  library(optparse)
})

stop2 <- function(...) {
  stop(paste0(..., collapse = ""), call. = FALSE)
}

option_list <- list(
  make_option(
    c("--gse"),
    type = "character",
    help = "GSE accession, e.g. GSE10288"
  ),
  make_option(
    c("--out_dir"),
    type = "character",
    default = "data_processed",
    help = "Canonical processed-data root (default: data_processed)"
  ),
  make_option(
    c("--scripts_dir"),
    type = "character",
    default = "V1_analysis/scripts",
    help = "Directory containing V1 executable scripts (default: V1_analysis/scripts)"
  ),
  make_option(
    c("--group_col"),
    type = "character",
    default = "group_label",
    help = "Grouping column used by DEG (default: group_label)"
  ),
  make_option(
    c("--padj_cutoff"),
    type = "double",
    default = 0.05,
    help = "Adjusted P-value cutoff (default: 0.05)"
  ),
  make_option(
    c("--lfc_cutoff"),
    type = "double",
    default = 1,
    help = "Absolute log2 fold-change cutoff (default: 1)"
  ),
  make_option(
    c("--require_deg_ready"),
    action = "store_true",
    default = FALSE,
    help = "Require exactly two groups and valid case/control mapping"
  ),
  make_option(
    c("--quiet"),
    action = "store_true",
    default = FALSE,
    help = "Suppress package-version details"
  )
)

opt <- parse_args(OptionParser(option_list = option_list))

if (is.null(opt$gse) || !nzchar(trimws(opt$gse))) {
  stop2("Missing --gse")
}

if (
  length(opt$padj_cutoff) != 1L ||
  !is.finite(opt$padj_cutoff) ||
  opt$padj_cutoff <= 0 ||
  opt$padj_cutoff > 1
) {
  stop2("--padj_cutoff must be greater than 0 and less than or equal to 1.")
}

if (
  length(opt$lfc_cutoff) != 1L ||
  !is.finite(opt$lfc_cutoff) ||
  opt$lfc_cutoff < 0
) {
  stop2("--lfc_cutoff must be greater than or equal to 0.")
}

if (!dir.exists(opt$scripts_dir)) {
  stop2("scripts_dir not found: ", opt$scripts_dir)
}

# The executable scripts live under V1_analysis/scripts, while shared
# validators currently live under V1_analysis/_lib. Support both layouts
# so the preflight remains compatible if the library is moved later.
validate_inputs_candidates <- unique(c(
  file.path(opt$scripts_dir, "_lib", "validate_inputs.R"),
  file.path(dirname(opt$scripts_dir), "_lib", "validate_inputs.R")
))

validate_inputs_path <- validate_inputs_candidates[
  file.exists(validate_inputs_candidates)
]

if (length(validate_inputs_path) == 0L) {
  stop2(
    "V1 input validator not found. Checked: ",
    paste(validate_inputs_candidates, collapse = ", ")
  )
}

validate_inputs_path <- validate_inputs_path[[1]]
message("V1 input validator: ", validate_inputs_path)
source(validate_inputs_path)

gse <- trimws(opt$gse)
base_dir <- file.path(opt$out_dir, gse)

expr_path <- file.path(base_dir, "expression_gene_log.tsv")
meta_path <- file.path(base_dir, "sample_metadata_merged.tsv")

validation <- validate_v1_inputs(
  expr_path = expr_path,
  meta_path = meta_path,
  two_group_required = isTRUE(opt$require_deg_ready)
)

expr_mat <- validation$expr_mat_included
meta_inc <- validation$meta_included_aligned

# Canonical expression must remain fully finite at the V1 boundary.
bad_mask <- !is.finite(expr_mat)

if (any(bad_mask)) {
  bad_idx <- which(bad_mask, arr.ind = TRUE)
  n_examples <- min(10L, nrow(bad_idx))

  examples <- paste0(
    rownames(expr_mat)[bad_idx[seq_len(n_examples), "row"]],
    ":",
    colnames(expr_mat)[bad_idx[seq_len(n_examples), "col"]]
  )

  stop2(
    "Canonical expression contains ",
    nrow(bad_idx),
    " non-finite values. Examples (gene:sample): ",
    paste(examples, collapse = ", ")
  )
}

group_levels <- sort(unique(as.character(meta_inc$group_label)))

if (isTRUE(opt$require_deg_ready)) {
  if (!(opt$group_col %in% names(meta_inc))) {
    stop2("DEG group column not found in merged metadata: ", opt$group_col)
  }

  group_values <- trimws(as.character(meta_inc[[opt$group_col]]))
  group_values[group_values == ""] <- NA_character_

  if (any(is.na(group_values))) {
    bad_samples <- meta_inc$sample_id[is.na(group_values)]
    stop2(
      "Included samples have missing ", opt$group_col, " values (up to 10): ",
      paste(head(bad_samples, 10), collapse = ", ")
    )
  }

  deg_group_levels <- sort(unique(group_values))

  if (length(deg_group_levels) != 2L) {
    stop2(
      "DEG requires exactly two ", opt$group_col,
      " levels, but found ", length(deg_group_levels), ": ",
      paste(deg_group_levels, collapse = ", ")
    )
  }

  if (!("case_control" %in% names(meta_inc))) {
    stop2(
      "Merged metadata must contain case_control before DEG. ",
      "Return to Decision Layer, assign case/control, and re-merge."
    )
  }

  case_control <- tolower(trimws(as.character(meta_inc$case_control)))
  case_control[case_control == ""] <- NA_character_

  if (any(is.na(case_control))) {
    bad_samples <- meta_inc$sample_id[is.na(case_control)]
    stop2(
      "Included samples have missing case_control values (up to 10): ",
      paste(head(bad_samples, 10), collapse = ", ")
    )
  }

  invalid_roles <- setdiff(unique(case_control), c("case", "control"))

  if (length(invalid_roles) > 0L) {
    stop2(
      "case_control contains unsupported values: ",
      paste(sort(invalid_roles), collapse = ", "),
      ". Allowed values are case and control."
    )
  }

  if (!setequal(unique(case_control), c("case", "control"))) {
    stop2(
      "case_control among included samples must contain both case and control. Found: ",
      paste(sort(unique(case_control)), collapse = ", ")
    )
  }

  role_map <- unique(data.frame(
    group_value = group_values,
    case_control = case_control,
    stringsAsFactors = FALSE
  ))

  groups_per_role <- split(role_map$group_value, role_map$case_control)
  roles_per_group <- split(role_map$case_control, role_map$group_value)

  if (
    any(vapply(groups_per_role, function(x) length(unique(x)) != 1L, logical(1))) ||
    any(vapply(roles_per_group, function(x) length(unique(x)) != 1L, logical(1)))
  ) {
    stop2(
      "Each ", opt$group_col,
      " level must map to exactly one case/control role, and each role must map ",
      "to exactly one group."
    )
  }

  group_levels <- deg_group_levels
}

package_versions <- vapply(
  required_packages,
  function(pkg) as.character(utils::packageVersion(pkg)),
  FUN.VALUE = character(1)
)

cat("=== V1 SANITY CHECK PASS ===\n")
cat("GSE: ", gse, "\n", sep = "")
cat("Expression: ", expr_path, "\n", sep = "")
cat("Metadata: ", meta_path, "\n", sep = "")
cat("Samples total in expression: ", validation$expr_info$n_samples_total, "\n", sep = "")
cat("Samples total in metadata: ", validation$meta_info$n_meta_total, "\n", sep = "")
cat("Samples included: ", validation$meta_info$n_meta_included, "\n", sep = "")
cat("Group levels (included): ", paste(group_levels, collapse = ", "), "\n", sep = "")
cat("Expression genes: ", validation$expr_info$n_genes, "\n", sep = "")
cat("Adjusted P cutoff: ", opt$padj_cutoff, "\n", sep = "")
cat("Absolute log2FC cutoff: ", opt$lfc_cutoff, "\n", sep = "")
cat("DEG readiness required: ", isTRUE(opt$require_deg_ready), "\n", sep = "")

if (!isTRUE(opt$quiet)) {
  cat("Required package versions:\n")
  for (pkg in required_packages) {
    cat("  - ", pkg, ": ", package_versions[[pkg]], "\n", sep = "")
  }
}
