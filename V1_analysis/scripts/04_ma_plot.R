#!/usr/bin/env Rscript
# 04_ma_plot.R
# MA plot from canonical outputs + DEG topTable
#
# Inputs (default):
#   data_processed/<GSE>/expression_gene_log.tsv
#   data_processed/<GSE>/sample_metadata_merged.tsv
#   results/<GSE>/deg/topTable.tsv
#
# Outputs:
#   figures/<GSE>/MA.png
#   results/<GSE>/ma_plot/MA_points_marked.tsv
#   results/<GSE>/ma_plot/runlog.txt
#   results/<GSE>/ma_plot/manifest.json
#
# Usage:
#   Rscript V1_analysis/scripts/04_ma_plot.R --gse GSE13601
#   Rscript V1_analysis/scripts/04_ma_plot.R --gse GSE13601 --padj_cutoff 0.01 --lfc_cutoff 1.5
#   Rscript V1_analysis/scripts/04_ma_plot.R --gse GSE13601 --topTable results/GSE13601/deg/topTable.tsv

suppressPackageStartupMessages({
  library(optparse)
  library(readr)
  library(dplyr)
  library(tibble)
  library(ggplot2)
})

stop2 <- function(...) stop(paste0(..., collapse = ""), call. = FALSE)

source("V1_analysis/_lib/validate_inputs.R")
source("V1_analysis/_lib/manifest.R")

option_list <- list(
  make_option(c("--gse"), type="character", help="GSE accession, e.g. GSE13601"),
  make_option(c("--topTable"), type="character", default="", help="Input topTable TSV (default: results/<GSE>/deg/topTable.tsv)"),
  make_option(c("--expr"), type="character", default="", help="Override expression path (default: data_processed/<GSE>/expression_gene_log.tsv)"),
  make_option(c("--meta"), type="character", default="", help="Override merged meta path (default: data_processed/<GSE>/sample_metadata_merged.tsv)"),
  make_option(c("--outroot"), type="character", default="figures", help="Figures root dir (default: figures)"),
  make_option(c("--output"), type="character", default="", help="Output png path (default: figures/<GSE>/MA.png)"),
  make_option(c("--padj_cutoff"), type="double", default=0.05, help="Adjusted P cutoff (default 0.05)"),
  make_option(c("--lfc_cutoff"), type="double", default=1, help="Abs(logFC) cutoff (default 1)"),
  make_option(c("--use_padj"), action="store_true", default=TRUE, help="Use adj.P.Val if available (default TRUE)"),
  make_option(c("--width"), type="double", default=7, help="Plot width in inches (default 7)"),
  make_option(c("--height"), type="double", default=6, help="Plot height in inches (default 6)"),
  make_option(c("--dpi"), type="integer", default=300, help="Plot DPI (default 300)"),
  make_option(c("--quiet"), action="store_true", default=FALSE, help="Quiet mode")
)

opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$gse) || opt$gse == "") stop2("Missing --gse")

gse <- opt$gse

# ---- defaults ----
expr_f <- file.path("data_processed", gse, "expression_gene_log.tsv")
meta_f <- file.path("data_processed", gse, "sample_metadata_merged.tsv")
top_f  <- file.path("results", gse, "deg", "topTable.tsv")

if (nzchar(opt$expr)) expr_f <- opt$expr
if (nzchar(opt$meta)) meta_f <- opt$meta
if (nzchar(opt$topTable)) top_f <- opt$topTable

if (!file.exists(expr_f)) stop2("Expression not found: ", expr_f)
if (!file.exists(meta_f)) stop2("Merged meta not found: ", meta_f)
if (!file.exists(top_f))  stop2("topTable not found: ", top_f)

# ---- output dirs ----
fig_dir <- file.path(opt$outroot, gse)                # images only
dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)

module_id <- "ma_plot"
res_dir <- file.path("results", gse, module_id)       # tables/logs/manifest
dir.create(res_dir, recursive = TRUE, showWarnings = FALSE)

out_png <- opt$output
if (!nzchar(out_png)) out_png <- file.path(fig_dir, "MA.png")

out_marked_tsv <- file.path(res_dir, "MA_points_marked.tsv")
runlog_path <- file.path(res_dir, "runlog.txt")
manifest_path <- file.path(res_dir, "manifest.json")

if (!opt$quiet) {
  message("GSE: ", gse)
  message("expr: ", expr_f)
  message("meta: ", meta_f)
  message("top : ", top_f)
  message("fig : ", fig_dir)
  message("res : ", res_dir)
}

padj_cutoff <- opt$padj_cutoff
lfc_cutoff  <- opt$lfc_cutoff

# ---- validate + get included objects ----
v <- validate_v1_inputs(expr_f, meta_f, two_group_required = TRUE)

expr_mat <- v$expr_mat_included          # gene_id x included samples
meta_inc <- v$meta_included_aligned      # aligned to expr_mat columns
if (is.null(expr_mat) || is.null(meta_inc)) stop2("Validator did not return aligned objects. Check validate_inputs.R (Route A).")

# ---- AveExpr from included samples only ----
ave <- rowMeans(expr_mat, na.rm = TRUE)
ave_df <- tibble(gene = names(ave), AveExpr = as.numeric(ave))

# ---- load topTable (from step 02) ----
tt <- suppressMessages(readr::read_tsv(top_f, show_col_types = FALSE))
names(tt) <- make.names(names(tt))

if (!("logFC" %in% names(tt))) stop2("topTable must contain column: logFC")

pcol <- if (isTRUE(opt$use_padj) && ("adj.P.Val" %in% names(tt))) {
  "adj.P.Val"
} else if ("P.Value" %in% names(tt)) {
  "P.Value"
} else {
  NA_character_
}
if (is.na(pcol)) stop2("topTable must contain adj.P.Val or P.Value")

gene_col <- if ("Gene.symbol" %in% names(tt)) {
  "Gene.symbol"
} else if ("ID" %in% names(tt)) {
  "ID"
} else {
  NA_character_
}
if (is.na(gene_col)) stop2("topTable must contain Gene.symbol or ID")

tt2 <- tt %>%
  transmute(
    gene  = as.character(.data[[gene_col]]),
    logFC = as.numeric(logFC),
    pval  = as.numeric(.data[[pcol]])
  ) %>%
  filter(is.finite(logFC), is.finite(pval), pval > 0, !is.na(gene), gene != "")

if (nrow(tt2) == 0) stop2("No valid rows in topTable after cleaning.")

# ---- merge + classify ----
plot_df <- tt2 %>%
  inner_join(ave_df, by = "gene") %>%
  mutate(
    pass_p   = pval <= padj_cutoff,
    pass_lfc = abs(logFC) >= lfc_cutoff,
    sig      = pass_p & pass_lfc,
    direction = dplyr::case_when(
      sig & logFC >=  lfc_cutoff ~ "Up",
      sig & logFC <= -lfc_cutoff ~ "Down",
      TRUE                       ~ "NS"
    )
  )

if (nrow(plot_df) == 0) stop2("No overlapping genes between topTable and expression (gene_id).")

# ---- write marked points (to results, not figures) ----
readr::write_tsv(
  plot_df %>% select(gene, AveExpr, logFC, pval, direction),
  out_marked_tsv
)

# ---- MA plot ----
p <- ggplot(plot_df, aes(x = AveExpr, y = logFC, color = direction)) +
  geom_point(size = 1.2, alpha = 0.9) +
  geom_hline(yintercept = c(-lfc_cutoff, lfc_cutoff), linetype = "dashed") +
  scale_color_manual(values = c(Up = "red", Down = "blue", NS = "grey70")) +
  labs(
    title = paste0(gse, " MA plot"),
    subtitle = paste0("cutoff: ", pcol, " <= ", padj_cutoff, ", |logFC| >= ", lfc_cutoff),
    x = "AveExpr (mean log2 expression; included samples)",
    y = "logFC",
    color = NULL
  ) +
  theme_bw() +
  theme(legend.position = "top")

ggsave(out_png, plot = p, width = opt$width, height = opt$height, dpi = opt$dpi)

# ---- runlog ----
n_total <- nrow(plot_df)
n_sig <- sum(plot_df$pval <= padj_cutoff & abs(plot_df$logFC) >= lfc_cutoff, na.rm = TRUE)
n_up <- sum(plot_df$direction == "Up", na.rm = TRUE)
n_down <- sum(plot_df$direction == "Down", na.rm = TRUE)

writeLines(c(
  paste0("GSE: ", gse),
  paste0("expr: ", expr_f),
  paste0("meta: ", meta_f),
  paste0("topTable: ", top_f),
  paste0("pcol_used: ", pcol),
  paste0("padj_cutoff: ", padj_cutoff),
  paste0("lfc_cutoff: ", lfc_cutoff),
  paste0("n_samples_included: ", ncol(expr_mat)),
  paste0("n_genes_in_plot: ", n_total),
  paste0("n_sig: ", n_sig),
  paste0("n_up: ", n_up),
  paste0("n_down: ", n_down),
  paste0("outputs(figures):"),
  paste0("  ", out_png),
  paste0("outputs(results):"),
  paste0("  ", out_marked_tsv),
  paste0("timestamp: ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
), con = runlog_path)

# ---- manifest.json ----
write_manifest_json(
  manifest_path = manifest_path,
  module_id = module_id,
  gse = gse,
  inputs = list(
    expr = expr_f,
    meta = meta_f,
    topTable = top_f
  ),
  outputs = list(
    ma_png = out_png,
    points_tsv = out_marked_tsv,
    runlog_txt = runlog_path
  ),
  args = list(
    outroot = opt$outroot,
    output = opt$output,
    padj_cutoff = padj_cutoff,
    lfc_cutoff = lfc_cutoff,
    use_padj = opt$use_padj,
    width = opt$width,
    height = opt$height,
    dpi = opt$dpi
  ),
  extra = list(
    pcol_used = pcol,
    n_samples_included = ncol(expr_mat),
    n_genes_in_plot = n_total,
    n_sig = n_sig,
    n_up = n_up,
    n_down = n_down
  )
)

if (!opt$quiet) {
  cat("Saved:\n")
  cat(" - ", normalizePath(out_png, winslash = "/", mustWork = FALSE), "\n", sep = "")
  cat(" - ", normalizePath(out_marked_tsv, winslash = "/", mustWork = FALSE), "\n", sep = "")
  cat(" - ", normalizePath(runlog_path, winslash = "/", mustWork = FALSE), "\n", sep = "")
  cat(" - ", normalizePath(manifest_path, winslash = "/", mustWork = FALSE), "\n", sep = "")
}
