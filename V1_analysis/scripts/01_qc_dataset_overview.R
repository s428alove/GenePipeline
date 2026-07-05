#!/usr/bin/env Rscript
# ============================================================
# 01_qc_dataset_overview.R  (FULL OVERWRITE)
# QC overview from canonical outputs:
#   data_processed/<GSE>/expression_gene_log.tsv
#   data_processed/<GSE>/sample_metadata_merged.tsv
#
# Output:
#   figures/<GSE>/PCA.png
#   figures/<GSE>/sample_distance_heatmap.png
#   figures/<GSE>/expression_boxplot.png
#   results/<GSE>/qc_dataset_overview/group_counts.tsv
#   results/<GSE>/qc_dataset_overview/runlog.txt
#   results/<GSE>/qc_dataset_overview/manifest.json
#
# QC overview from canonical outputs.
# QC status is review evidence only.
# This script does not modify inclusion or stop downstream analysis by itself.
# ============================================================

# ---- resolve script dir for robust source() ----
args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("^--file=", "", args[grep("^--file=", args)])
script_dir  <- dirname(normalizePath(script_path))

suppressPackageStartupMessages({
  library(optparse)
  library(dplyr)
  library(tidyr)
  library(tibble)
  library(stringr)
  library(ggplot2)
  library(pheatmap)
})

stop2 <- function(...) stop(paste0(..., collapse=""), call. = FALSE)

# ---- source libs (robust paths) ----
source("V1_analysis/_lib/validate_inputs.R")
source("V1_analysis/_lib/manifest.R")

option_list <- list(
  make_option(c("--gse"), type="character"),
  make_option(c("--outroot"), type="character", default="figures"),
  make_option(c("--dpi"), type="integer", default=300),
  make_option(c("--width"), type="double", default=7),
  make_option(c("--height"), type="double", default=5),
  make_option(c("--expr"), type="character", default=""),
  make_option(c("--meta"), type="character", default=""),
  make_option(c("--group_col"), type="character", default=""),
  make_option(c("--min_n_total"), type="integer", default=4),
  make_option(c("--min_n_per_group"), type="integer", default=2),
  make_option(c("--require_ge2_groups"), action="store_true", default=TRUE),
  make_option(c("--pca_max_genes"), type="integer", default=5000,
              help="For PCA, optionally subsample genes to reduce memory; 0 means no subsample.")
)
opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$gse) || opt$gse == "") stop2("Missing --gse")

gse <- opt$gse

expr_f <- file.path("data_processed", gse, "expression_gene_log.tsv")
meta_f <- file.path("data_processed", gse, "sample_metadata_merged.tsv")
if (nzchar(opt$expr)) expr_f <- opt$expr
if (nzchar(opt$meta)) meta_f <- opt$meta

# figures dir (ONLY images)
fig_dir <- file.path(opt$outroot, gse)
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

# results dir (logs + manifest)
module_id <- "qc_dataset_overview"
res_dir <- file.path("results", gse, module_id)
dir.create(res_dir, recursive = TRUE, showWarnings = FALSE)

message("GSE: ", gse)
message("expr: ", expr_f)
message("meta: ", meta_f)
message("fig : ", fig_dir)
message("res : ", res_dir)

# QC: no need to force 2 groups at validator level; review evidence is summarized here
v <- validate_v1_inputs(expr_f, meta_f, two_group_required = FALSE)

expr_mat <- v$expr_mat_included
meta_inc <- v$meta_included_aligned
if (is.null(expr_mat) || is.null(meta_inc)) stop2("Validator did not return aligned objects. Check validate_inputs.R.")

# choose group column for coloring and review summary
group_col <- "group_label"
if (nzchar(opt$group_col)) {
  if (!(opt$group_col %in% names(meta_inc))) stop2("--group_col not found in merged meta: ", opt$group_col)
  group_col <- opt$group_col
}
if (group_col == "include") stop2("Refusing to color by 'include'.")

# Ensure alignment order explicitly: meta_inc rows must match expr_mat columns
meta_inc <- meta_inc[match(colnames(expr_mat), meta_inc$sample_id), , drop = FALSE]
if (any(is.na(meta_inc$sample_id))) stop2("Alignment error after re-ordering meta_inc.")

meta_inc$group <- as.character(meta_inc[[group_col]])
meta_inc$group[is.na(meta_inc$group) | trimws(meta_inc$group) == ""] <- "NA"
meta_inc$group <- factor(meta_inc$group)

# optional batch annotation (heatmap only)
batch_col <- if ("batch" %in% names(meta_inc)) "batch" else NULL
meta_inc$batch2 <- if (!is.null(batch_col)) {
  bb <- as.character(meta_inc[[batch_col]])
  bb[is.na(bb) | trimws(bb) == ""] <- "NA"
  factor(bb)
} else {
  NA
}

safe_palette <- function(n) {
  if (n <= 0) return(character(0))
  grDevices::hcl.colors(n, palette = "Dark 3")
}

# ----------------------------
# QC review evidence summary
# ----------------------------
group_counts <- meta_inc %>%
  count(group, name = "n") %>%
  arrange(desc(n))

n_total <- nrow(meta_inc)
n_groups <- nrow(group_counts)
min_per_group <- if (n_groups == 0) NA_integer_ else min(group_counts$n)

review_status <- "PASS"
review_notes <- character(0)

if (n_total < opt$min_n_total) {
  review_status <- "REVIEW"
  
  review_notes <- c(
    review_notes,
    paste0(
      "n_total_included<",
      opt$min_n_total,
      " (",n_total,")"
    )
  )
}
if (isTRUE(opt$require_ge2_groups) && n_groups < 2) {
  review_status <- "REVIEW"
  review_notes <- c(review_notes, paste0("n_groups<2 (", n_groups, ")"))
}

if (!is.na(min_per_group) && min_per_group < opt$min_n_per_group) {
  review_status <- "REVIEW"
  review_notes <- c(review_notes, paste0("min_n_per_group<", opt$min_n_per_group, " (", min_per_group, ")"))
}

# Write group counts (results)
group_counts_path <- file.path(res_dir, "group_counts.tsv")
readr::write_tsv(group_counts, group_counts_path)
message("Saved: ", group_counts_path)

# ----------------------------
# Prepare matrices for PCA/dist
# expr_t: sample x gene
# ----------------------------
expr_t <- t(expr_mat)

# fill NA for stability (gene-wise median)
if (anyNA(expr_t)) {
  for (j in seq_len(ncol(expr_t))) {
    colv <- expr_t[, j]
    if (anyNA(colv)) {
      med <- median(colv, na.rm = TRUE)
      colv[is.na(colv)] <- med
      expr_t[, j] <- colv
    }
  }
}

# OPTIONAL: gene subsample for PCA speed
if (!is.null(opt$pca_max_genes) && opt$pca_max_genes > 0 && ncol(expr_t) > opt$pca_max_genes) {
  set.seed(1)
  keep_idx <- sample(seq_len(ncol(expr_t)), opt$pca_max_genes)
  expr_t_pca <- expr_t[, keep_idx, drop = FALSE]
} else {
  expr_t_pca <- expr_t
}

# CRITICAL FIX: remove zero-variance genes before PCA with scale.=TRUE
# (prcomp will fail if any column has sd==0)
sdv <- apply(expr_t_pca, 2, sd, na.rm = TRUE)
keep_var <- which(is.finite(sdv) & sdv > 0)

n_zero_var <- ncol(expr_t_pca) - length(keep_var)
if (length(keep_var) < 2) {
  stop2(
    "PCA blocked: too few variable genes after removing zero-variance columns.\n",
    "n_samples_included=", nrow(expr_t_pca), ", n_genes_pca=", ncol(expr_t_pca),
    ", n_zero_var_removed=", n_zero_var, "\n",
    "Hint: check include samples count / log transform / dataset quality."
  )
}
expr_t_pca2 <- expr_t_pca[, keep_var, drop = FALSE]

# ----------------------------
# 1) PCA
# ----------------------------
pca <- prcomp(expr_t_pca2, scale. = TRUE)

pca_df <- data.frame(
  sample_id = rownames(pca$x),
  PC1 = pca$x[, 1],
  PC2 = pca$x[, 2],
  stringsAsFactors = FALSE
) %>%
  left_join(meta_inc %>% dplyr::select(sample_id, group), by = "sample_id")

p_pca <- ggplot(pca_df, aes(x = PC1, y = PC2, color = group)) +
  geom_point(size = 2.8, alpha = 0.9) +
  theme_bw() +
  labs(
    title = paste0(gse, " PCA"),
    subtitle = paste0("Color: ", group_col, " | Review: ", review_status,
                      " | PCA genes: ", ncol(expr_t_pca2),
                      if (n_zero_var > 0) paste0(" (removed zero-var: ", n_zero_var, ")") else ""),
    x = "PC1", y = "PC2", color = NULL
  ) +
  theme(legend.position = "right")

pca_png <- file.path(fig_dir, "PCA.png")
ggsave(pca_png, p_pca, width = opt$width, height = opt$height, dpi = opt$dpi)
message("Saved: ", pca_png)

# ----------------------------
# 2) Sample distance heatmap
# ----------------------------
dist_m <- as.matrix(dist(expr_t, method = "euclidean"))
rownames(dist_m) <- colnames(dist_m) <- rownames(expr_t)

ann_col <- data.frame(group = meta_inc$group, row.names = meta_inc$sample_id)
ann_colors <- list(group = setNames(safe_palette(nlevels(meta_inc$group)), levels(meta_inc$group)))

subtitle_hm <- paste0("Color: ", group_col)
if (!all(is.na(meta_inc$batch2))) {
  ann_col$batch <- meta_inc$batch2
  ann_colors$batch <- setNames(safe_palette(nlevels(meta_inc$batch2)), levels(meta_inc$batch2))
  subtitle_hm <- paste0(subtitle_hm, " | Batch: ", batch_col)
}

hm_png <- file.path(fig_dir, "sample_distance_heatmap.png")
png(hm_png, width = 1400, height = 1200, res = opt$dpi)
pheatmap::pheatmap(
  dist_m,
  annotation_col = ann_col,
  annotation_row = ann_col,
  annotation_colors = ann_colors,
  main = paste0(gse, " Sample distance (", subtitle_hm, ")"),
  show_rownames = FALSE,
  show_colnames = FALSE
)
dev.off()
message("Saved: ", hm_png)

# ----------------------------
# 3) Expression distribution boxplot
# ----------------------------
max_genes_for_box <- 2000L
set.seed(1)
expr_for_plot <- expr_mat
if (nrow(expr_for_plot) > max_genes_for_box) {
  idx <- sample(seq_len(nrow(expr_for_plot)), max_genes_for_box)
  expr_for_plot <- expr_for_plot[idx, , drop = FALSE]
}

expr_long <- expr_for_plot %>%
  as.data.frame() %>%
  tibble::rownames_to_column("gene_id") %>%
  tidyr::pivot_longer(cols = -gene_id, names_to = "sample_id", values_to = "expression") %>%
  left_join(meta_inc %>% dplyr::select(sample_id, group), by = "sample_id")

p_box <- ggplot(expr_long, aes(x = sample_id, y = expression, fill = group)) +
  geom_boxplot(outlier.size = 0.35, linewidth = 0.25) +
  theme_bw() +
  theme(
    axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5),
    legend.position = "right"
  ) +
  labs(
    title = paste0(gse, " Expression distribution"),
    subtitle = paste0("Color: ", group_col, " | ", min(max_genes_for_box, nrow(expr_mat)), " genes | Review:",review_status),
    x = "Sample", y = "Expression", fill = NULL
  )

box_png <- file.path(fig_dir, "expression_boxplot.png")
ggsave(box_png, p_box, width = max(opt$width, 10), height = max(opt$height, 5), dpi = opt$dpi)
message("Saved: ", box_png)

# ----------------------------
# Run log (results)
# ----------------------------
log_file <- file.path(res_dir, "runlog.txt")
writeLines(c(
  paste0("GSE: ", gse),
  paste0("expr: ", expr_f),
  paste0("meta: ", meta_f),
  paste0("n_genes: ", nrow(expr_mat)),
  paste0("n_samples_included: ", ncol(expr_mat)),
  paste0("group_col(used): ", group_col),
  paste0("group_levels(included): ", paste(levels(meta_inc$group), collapse = ", ")),
  paste0("QC_REVIEW_STATUS:",review_status),
  paste0("QC_REVIEW_NOTES: ", if (length(review_notes) == 0) "" else paste(review_notes, collapse = " | ")),
  paste0("PCA_genes_used: ", ncol(expr_t_pca2)),
  paste0("PCA_zero_var_removed: ", n_zero_var),
  paste0("group_counts.tsv: ", group_counts_path),
  paste0("outputs(figures):"),
  paste0("  ", pca_png),
  paste0("  ", hm_png),
  paste0("  ", box_png)
), con = log_file)
message("Saved: ", log_file)

# ----------------------------
# Manifest (results)
# ----------------------------
manifest_path <- file.path(res_dir, "manifest.json")

write_manifest_json(
  manifest_path = manifest_path,
  module_id = module_id,
  gse = gse,
  inputs = list(expr = expr_f, meta = meta_f),
  outputs = list(
    pca_png = pca_png,
    heatmap_png = hm_png,
    boxplot_png = box_png,
    group_counts_tsv = group_counts_path,
    runlog_txt = log_file
  ),
  args = list(
    outroot = opt$outroot,
    dpi = opt$dpi,
    width = opt$width,
    height = opt$height,
    expr = opt$expr,
    meta = opt$meta,
    group_col = opt$group_col,
    min_n_total = opt$min_n_total,
    min_n_per_group = opt$min_n_per_group,
    require_ge2_groups = opt$require_ge2_groups,
    pca_max_genes = opt$pca_max_genes
  ),
  extra = list(
    qc_review_status=review_status,
    qc_review_notes=review_notes,
    n_samples_included = ncol(expr_mat),
    n_genes = nrow(expr_mat),
    group_col_used = group_col,
    group_levels_included = levels(meta_inc$group),
    group_counts = as.list(setNames(group_counts$n, as.character(group_counts$group))),
    pca_genes_used = ncol(expr_t_pca2),
    pca_zero_var_removed = n_zero_var
  )
)
message("Saved manifest: ", manifest_path)

message("Done (QC review = ", review_status, ").")

