#!/usr/bin/env Rscript
# 02_run_differential_expression.R
# Differential expression (limma) from canonical outputs:
#   data_processed/<GSE>/expression_gene_log.tsv
#   data_processed/<GSE>/sample_metadata_merged.tsv
#
# Direction rule (fixed):
#   logFC = case - control
#   - group labels used for plotting/labels: group_label (or --group_col)
#   - direction inferred from meta_inc$case_control (case/control)
#
# Output:
#   results/<GSE>/deg/topTable.tsv
#   results/<GSE>/deg/deg_summary.txt
#   results/<GSE>/deg/manifest.json
#
# Usage:
#   Rscript V1_analysis/scripts/02_run_differential_expression.R --gse GSE13601
#   Rscript V1_analysis/scripts/02_run_differential_expression.R --gse GSE13601 --case_label Tumor --control_label Normal
#   Rscript V1_analysis/scripts/02_run_differential_expression.R --gse GSE13601 --group_col group_label --batch_col batch

suppressPackageStartupMessages({
  library(optparse)
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(limma)
})

stop2 <- function(...) stop(paste0(..., collapse=""), call. = FALSE)

source("V1_analysis/_lib/validate_inputs.R")
source("V1_analysis/_lib/manifest.R")

option_list <- list(
  make_option(c("--gse"), type="character", help="GSE accession, e.g. GSE13601"),
  make_option(c("--expr"), type="character", default="", help="Override expression path"),
  make_option(c("--meta"), type="character", default="", help="Override merged metadata path"),
  make_option(c("--group_col"), type="character", default="group_label", help="Group column in merged meta (default: group_label)"),
  make_option(c("--batch_col"), type="character", default="batch", help="Batch column in merged meta (default: batch)"),
  make_option(c("--case_label"), type="character", default="", help="Override: Case level name (must match group levels)"),
  make_option(c("--control_label"), type="character", default="", help="Override: Control level name (must match group levels)"),
  make_option(c("--padj_cutoff"), type="double", default=0.05, help="Adjusted P cutoff (BH)"),
  make_option(c("--lfc_cutoff"), type="double", default=1, help="Abs(logFC) cutoff (for summary only)"),
  make_option(c("--quiet"), action="store_true", default=FALSE, help="Quiet mode")
)
opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$gse) || opt$gse=="") stop2("Missing --gse")

gse <- opt$gse

expr_f <- file.path("data_processed", gse, "expression_gene_log.tsv")
meta_f <- file.path("data_processed", gse, "sample_metadata_merged.tsv")
if (nzchar(opt$expr)) expr_f <- opt$expr
if (nzchar(opt$meta)) meta_f <- opt$meta

# results dir
out_dir <- file.path("results", gse, "deg")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!opt$quiet) {
  message("GSE: ", gse)
  message("expr: ", expr_f)
  message("meta: ", meta_f)
  message("out : ", out_dir)
}

# ---- validate (two-group required for DEG) ----
v <- validate_v1_inputs(expr_f, meta_f, two_group_required = TRUE)

expr_mat <- v$expr_mat_included
meta_inc <- v$meta_included_aligned
if (is.null(expr_mat) || is.null(meta_inc)) {
  stop2("Validator did not return aligned objects. Check validate_inputs.R (Route A).")
}

# ---- group column (labels + design groups) ----
if (!(opt$group_col %in% names(meta_inc))) stop2("group_col not found in merged meta: ", opt$group_col)

grp_raw <- as.character(meta_inc[[opt$group_col]])
grp_raw[is.na(grp_raw) | trimws(grp_raw)==""] <- NA_character_
if (any(is.na(grp_raw))) stop2("group_col contains NA/empty among included samples. Fix merged meta or choose another --group_col.")

group_levels <- sort(unique(grp_raw))
if (length(group_levels) != 2) {
  stop2("two-group required but found ", length(group_levels), " group levels: ", paste(group_levels, collapse=", "))
}

# ---- direction source of truth: case_control ----
if (!("case_control" %in% names(meta_inc))) {
  stop2("Merged meta must contain 'case_control' for DEG direction. Please fill sample_metadata_decision.tsv and re-merge.")
}

cc <- tolower(trimws(as.character(meta_inc$case_control)))
cc[cc == ""] <- NA_character_

if (any(is.na(cc))) {
  bad <- meta_inc$sample_id[is.na(cc)]
  stop2("case_control has NA/empty among included samples (need case/control). sample_id (up to 10): ",
        paste(head(bad, 10), collapse = ", "))
}

need_cc <- c("case", "control")
if (!all(need_cc %in% unique(cc))) {
  stop2("case_control among included must contain both 'case' and 'control'. Found: ",
        paste(sort(unique(cc)), collapse = ", "))
}

# map case/control -> group_label (or chosen group_col)
map_df <- tibble(
  sample_id = meta_inc$sample_id,
  group_val = grp_raw,
  case_control = cc
)

case_groups <- sort(unique(map_df$group_val[map_df$case_control == "case"]))
ctrl_groups <- sort(unique(map_df$group_val[map_df$case_control == "control"]))

if (length(case_groups) != 1) {
  stop2("Invalid mapping: case_control=='case' must map to exactly 1 ", opt$group_col, " level. Found: ",
        paste(case_groups, collapse = ", "))
}
if (length(ctrl_groups) != 1) {
  stop2("Invalid mapping: case_control=='control' must map to exactly 1 ", opt$group_col, " level. Found: ",
        paste(ctrl_groups, collapse = ", "))
}

case_lab_inferred <- case_groups[1]
ctrl_lab_inferred <- ctrl_groups[1]

if (case_lab_inferred == ctrl_lab_inferred) {
  stop2("Invalid mapping: case and control map to the same group level: ", case_lab_inferred)
}

# ---- allow DEG direction override via CLI (optional) ----
if (nzchar(opt$case_label) || nzchar(opt$control_label)) {
  if (!(nzchar(opt$case_label) && nzchar(opt$control_label))) {
    stop2("If overriding direction, you must provide BOTH --case_label and --control_label.")
  }
  if (!(opt$case_label %in% group_levels)) stop2("--case_label not in group levels: ", opt$case_label)
  if (!(opt$control_label %in% group_levels)) stop2("--control_label not in group levels: ", opt$control_label)
  if (opt$case_label == opt$control_label) stop2("case_label and control_label cannot be the same.")
  case_lab <- opt$case_label
  ctrl_lab <- opt$control_label
} else {
  case_lab <- case_lab_inferred
  ctrl_lab <- ctrl_lab_inferred
}

# ensure case/control labels cover the two group levels
if (!setequal(c(case_lab, ctrl_lab), group_levels)) {
  stop2(
    "Direction labels do not match the two group levels.\n",
    "Group levels: ", paste(group_levels, collapse = ", "), "\n",
    "case/control: ", paste(c(case_lab, ctrl_lab), collapse = ", ")
  )
}

# Build factor with baseline = control => logFC = case - control
grp <- factor(grp_raw, levels = c(ctrl_lab, case_lab))

# ---- optional batch ----
use_batch <- FALSE
batch_term <- NULL
batch_col_used <- NA_character_
if (nzchar(opt$batch_col) && (opt$batch_col %in% names(meta_inc))) {
  b <- as.character(meta_inc[[opt$batch_col]])
  b[is.na(b) | trimws(b)=="" | b=="NA"] <- NA_character_
  if (sum(!is.na(b)) >= 2 && length(unique(na.omit(b))) >= 2) {
    use_batch <- TRUE
    batch_term <- factor(b)
    batch_col_used <- opt$batch_col
  }
}

# ---- limma design + contrast ----
if (use_batch) {
  design <- model.matrix(~ 0 + grp + batch_term)
  colnames(design) <- make.names(colnames(design))
  c_case <- make.names(paste0("grp", case_lab))
  c_ctrl <- make.names(paste0("grp", ctrl_lab))
  if (!(c_case %in% colnames(design)) || !(c_ctrl %in% colnames(design))) {
    stop2("Design matrix missing group columns: ", c_ctrl, ", ", c_case)
  }
  contr <- rep(0, ncol(design)); names(contr) <- colnames(design)
  contr[c_case] <-  1
  contr[c_ctrl] <- -1
} else {
  design <- model.matrix(~ 0 + grp)
  colnames(design) <- make.names(colnames(design))
  c_case <- make.names(paste0("grp", case_lab))
  c_ctrl <- make.names(paste0("grp", ctrl_lab))
  if (!(c_case %in% colnames(design)) || !(c_ctrl %in% colnames(design))) {
    stop2("Design matrix missing group columns: ", c_ctrl, ", ", c_case)
  }
  contr <- rep(0, ncol(design)); names(contr) <- colnames(design)
  contr[c_case] <-  1
  contr[c_ctrl] <- -1
}

# ---- run limma ----
fit <- lmFit(expr_mat, design)
fit2 <- contrasts.fit(fit, contr)
fit2 <- eBayes(fit2)

tt <- topTable(fit2, number = Inf, adjust.method = "BH", sort.by = "P")

# GEO2R-like table (rowname as ID)
out <- tt %>%
  rownames_to_column("ID") %>%
  transmute(
    ID = ID,
    adj.P.Val = adj.P.Val,
    P.Value   = P.Value,
    t         = t,
    B         = B,
    logFC     = logFC,
    Gene.symbol = ID,
    Gene.title  = NA_character_
  )

out_path <- file.path(out_dir, "topTable.tsv")
readr::write_tsv(out, out_path)

# ---- summary ----
n_total <- nrow(out)
n_sig <- sum(out$adj.P.Val <= opt$padj_cutoff & abs(out$logFC) >= opt$lfc_cutoff, na.rm = TRUE)

n_ctrl <- sum(grp == ctrl_lab, na.rm = TRUE)
n_case <- sum(grp == case_lab, na.rm = TRUE)

summary_path <- file.path(out_dir, "deg_summary.txt")
writeLines(c(
  paste0("GSE: ", gse),
  paste0("expr: ", expr_f),
  paste0("meta: ", meta_f),
  paste0("group_col: ", opt$group_col),
  paste0("direction_source: case_control"),
  paste0("control_label: ", ctrl_lab),
  paste0("case_label: ", case_lab),
  paste0("inferred_control_label_from_case_control: ", ctrl_lab_inferred),
  paste0("inferred_case_label_from_case_control: ", case_lab_inferred),
  paste0("n_control: ", n_ctrl),
  paste0("n_case: ", n_case),
  paste0("batch_used: ", use_batch),
  paste0("batch_col_used: ", ifelse(is.na(batch_col_used), "NA", batch_col_used)),
  paste0("padj_cutoff: ", opt$padj_cutoff),
  paste0("lfc_cutoff: ", opt$lfc_cutoff),
  paste0("n_genes_tested: ", n_total),
  paste0("n_sig(padj<=cutoff & |logFC|>=cutoff): ", n_sig),
  paste0("timestamp: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
), con = summary_path)

# ---- manifest.json ----
manifest_path <- file.path(out_dir, "manifest.json")
write_manifest_json(
  manifest_path = manifest_path,
  module_id = "deg",
  gse = gse,
  inputs = list(expr = expr_f, meta = meta_f),
  outputs = list(topTable_tsv = out_path, deg_summary_txt = summary_path),
  args = list(
    group_col = opt$group_col,
    batch_col = opt$batch_col,
    control_label = opt$control_label,
    case_label = opt$case_label,
    padj_cutoff = opt$padj_cutoff,
    lfc_cutoff = opt$lfc_cutoff
  ),
  extra = list(
    direction_source = "case_control",
    inferred_control_label = ctrl_lab_inferred,
    inferred_case_label = case_lab_inferred,
    used_control_label = ctrl_lab,
    used_case_label = case_lab,
    batch_used = use_batch,
    batch_col_used = batch_col_used,
    n_control = n_ctrl,
    n_case = n_case,
    n_genes_tested = n_total,
    n_sig = n_sig
  )
)

if (!opt$quiet) {
  cat("Saved:\n")
  cat(" - ", out_path, "\n", sep="")
  cat(" - ", summary_path, "\n", sep="")
  cat(" - ", manifest_path, "\n", sep="")
}
