#!/usr/bin/env Rscript
# 03_volcano_plot.R
# Volcano plot from DEG topTable:
#   results/<GSE>/deg/topTable.tsv
#
# Outputs (Scheme A):
#   figures/<GSE>/Volcano.png
#   results/<GSE>/volcano/Volcano_points_marked.tsv
#   results/<GSE>/volcano/manifest.json
#
# Usage:
#   Rscript V1_analysis/scripts/03_volcano_plot.R --gse GSE13601
#   Rscript V1_analysis/scripts/03_volcano_plot.R --gse GSE13601 --padj_cutoff 0.01 --lfc_cutoff 1
#   Rscript V1_analysis/scripts/03_volcano_plot.R --gse GSE13601 --input results/GSE13601/deg/topTable.tsv

suppressPackageStartupMessages({
  library(optparse)
  library(readr)
  library(dplyr)
  library(stringr)
  library(ggplot2)
})

stop2 <- function(...) stop(paste0(..., collapse = ""), call. = FALSE)

source("V1_analysis/_lib/manifest.R")

option_list <- list(
  make_option(c("--gse"), type = "character", help = "GSE accession, e.g., GSE13601"),
  make_option(c("--input"), type = "character", default = "",
              help = "Input topTable TSV (default: results/<GSE>/deg/topTable.tsv)"),
  make_option(c("--figroot"), type = "character", default = "figures",
              help = "Figures root dir (default: figures)"),
  make_option(c("--resroot"), type = "character", default = "results",
              help = "Results root dir (default: results)"),
  make_option(c("--output_png"), type = "character", default = "",
              help = "Output PNG path (default: figures/<GSE>/Volcano.png)"),
  make_option(c("--padj_cutoff"), type = "double", default = 0.05,
              help = "Adjusted P cutoff (default 0.05)"),
  make_option(c("--lfc_cutoff"), type = "double", default = 1,
              help = "Abs(logFC) cutoff (default 1)"),
  make_option(c("--label_top"), type = "integer", default = 10,
              help = "Label top N significant genes by p-value (default 10, 0 to disable)"),
  make_option(c("--use_padj"), action = "store_true", default = TRUE,
              help = "Use adj.P.Val if available (default TRUE)"),
  make_option(c("--width"), type = "double", default = 7,
              help = "Plot width in inches (default 7)"),
  make_option(c("--height"), type = "double", default = 6,
              help = "Plot height in inches (default 6)"),
  make_option(c("--dpi"), type = "integer", default = 300,
              help = "Plot DPI (default 300)"),
  make_option(c("--quiet"), action = "store_true", default = FALSE,
              help = "Quiet mode")
)

opt <- parse_args(OptionParser(option_list = option_list))

if (is.null(opt$gse) || opt$gse == "") stop2("Missing --gse")

gse <- opt$gse

# ---- default input/output paths ----
in_path <- opt$input
if (!nzchar(in_path)) {
  in_path <- file.path(opt$resroot, gse, "deg", "topTable.tsv")
}

fig_dir <- file.path(opt$figroot, gse)
res_dir <- file.path(opt$resroot, gse, "volcano")

dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(res_dir, recursive = TRUE, showWarnings = FALSE)

out_png <- opt$output_png
if (!nzchar(out_png)) out_png <- file.path(fig_dir, "Volcano.png")

out_marked_tsv <- file.path(res_dir, "Volcano_points_marked.tsv")
manifest_path  <- file.path(res_dir, "manifest.json")

if (!file.exists(in_path)) stop2("Input not found: ", in_path)

if (!opt$quiet) {
  message("GSE: ", gse)
  message("input: ", in_path)
  message("out_png: ", out_png)
  message("out_points: ", out_marked_tsv)
  message("manifest: ", manifest_path)
}

padj_cutoff <- opt$padj_cutoff
lfc_cutoff  <- opt$lfc_cutoff

# ---- load ----
df <- suppressMessages(readr::read_tsv(in_path, show_col_types = FALSE))
names(df) <- make.names(names(df))

if (!("logFC" %in% names(df))) stop2("Input must contain column: logFC")

pcol <- if (isTRUE(opt$use_padj) && ("adj.P.Val" %in% names(df))) {
  "adj.P.Val"
} else if ("P.Value" %in% names(df)) {
  "P.Value"
} else {
  NA_character_
}
if (is.na(pcol)) stop2("Input must contain adj.P.Val or P.Value")

gene_col <- if ("Gene.symbol" %in% names(df)) {
  "Gene.symbol"
} else if ("ID" %in% names(df)) {
  "ID"
} else {
  NA_character_
}
if (is.na(gene_col)) stop2("Input must contain Gene.symbol or ID")

plot_df <- df %>%
  mutate(
    pval = suppressWarnings(as.numeric(.data[[pcol]])),
    logFC = suppressWarnings(as.numeric(.data[["logFC"]])),
    gene  = as.character(.data[[gene_col]])
  ) %>%
  filter(is.finite(logFC), is.finite(pval), pval > 0) %>%
  mutate(
    neglog10p = -log10(pval),
    pass_p    = pval <= padj_cutoff,
    pass_lfc  = abs(logFC) >= lfc_cutoff,
    sig       = pass_p & pass_lfc,
    direction = case_when(
      sig & logFC >=  lfc_cutoff ~ "Up",
      sig & logFC <= -lfc_cutoff ~ "Down",
      TRUE                       ~ "NS"
    )
  )

if (nrow(plot_df) == 0) stop2("No valid rows after cleaning (check logFC/p-values).")

# labels: top N among sig, by smallest pval
label_n <- max(0L, as.integer(opt$label_top))
label_df <- plot_df %>%
  filter(direction %in% c("Up", "Down")) %>%
  arrange(pval) %>%
  slice_head(n = label_n)

# write points table (results/<GSE>/volcano/)
readr::write_tsv(
  plot_df %>% select(gene, logFC, pval, neglog10p, direction),
  out_marked_tsv
)

# plot (GEO2R-ish: Up=red, Down=blue, NS=grey)
p <- ggplot(plot_df, aes(x = logFC, y = neglog10p, color = direction)) +
  geom_point(size = 1.2, alpha = 0.9) +
  geom_vline(xintercept = c(-lfc_cutoff, lfc_cutoff), linetype = "dashed") +
  geom_hline(yintercept = -log10(padj_cutoff), linetype = "dashed") +
  scale_color_manual(values = c(Up = "red", Down = "blue", NS = "grey70")) +
  labs(
    title = paste0(gse, " Volcano"),
    subtitle = paste0("cutoff: ", pcol, " <= ", padj_cutoff, ", |logFC| >= ", lfc_cutoff),
    x = "logFC",
    y = paste0("-log10(", pcol, ")"),
    color = NULL
  ) +
  theme_bw() +
  theme(legend.position = "top")

if (label_n > 0 && nrow(label_df) > 0) {
  p <- p + geom_text(
    data = label_df,
    aes(label = gene),
    vjust = -0.6,
    size = 3,
    check_overlap = TRUE
  )
}

ggsave(out_png, plot = p, width = opt$width, height = opt$height, dpi = opt$dpi)

# ---- manifest.json (results/<GSE>/volcano/) ----
write_manifest_json(
  manifest_path = manifest_path,
  module_id = "volcano",
  gse = gse,
  inputs = list(
    topTable_tsv = in_path
  ),
  outputs = list(
    volcano_png = out_png,
    volcano_points_marked_tsv = out_marked_tsv
  ),
  args = list(
    figroot = opt$figroot,
    resroot = opt$resroot,
    output_png = opt$output_png,
    padj_cutoff = opt$padj_cutoff,
    lfc_cutoff = opt$lfc_cutoff,
    label_top = opt$label_top,
    use_padj = opt$use_padj,
    width = opt$width,
    height = opt$height,
    dpi = opt$dpi
  ),
  extra = list(
    p_value_column = pcol,
    gene_column = gene_col,
    n_points = nrow(plot_df),
    n_sig = sum(plot_df$direction %in% c("Up", "Down")),
    n_up = sum(plot_df$direction == "Up"),
    n_down = sum(plot_df$direction == "Down")
  )
)

cat("Saved:\n")
cat(" - ", normalizePath(out_png, winslash = "/", mustWork = FALSE), "\n", sep = "")
cat(" - ", normalizePath(out_marked_tsv, winslash = "/", mustWork = FALSE), "\n", sep = "")
cat(" - ", normalizePath(manifest_path, winslash = "/", mustWork = FALSE), "\n", sep = "")
