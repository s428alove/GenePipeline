#!/usr/bin/env Rscript
# ============================================================
# 10_targeted_gene_distribution.R (FLOW-2 OVERWRITE)
# One script, optional trend outputs controlled by --enable_trend.
#
# Per gene outputs:
#   - main plot (violin OR box) + jitter
#   - stats.tsv (wilcox/kruskal)
#   - (optional) ordered trend plot + trend_stats.tsv if enable_trend=TRUE
#
# Inputs:
#   data_processed/<GSE>/expression_gene_log.tsv
#   data_processed/<GSE>/sample_metadata_merged.tsv
# ============================================================

# ---- resolve script dir for robust source() ----
args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("^--file=", "", args[grep("^--file=", args)])
script_dir  <- dirname(normalizePath(script_path))

suppressPackageStartupMessages({
  library(optparse)
  library(dplyr)
  library(stringr)
  library(readr)
})

stop2 <- function(...) stop(paste0(..., collapse=""), call. = FALSE)

source(file.path(script_dir, "_lib", "validate_inputs.R"))
source(file.path(script_dir, "_lib", "manifest.R"))
source(file.path(script_dir, "_lib", "targeted_gene_helpers.R"))

# ----------------------------
# helpers
# ----------------------------
parse_bool_tf <- function(x, nm = "flag") {
  x0 <- tolower(str_trim(as.character(x)))
  if (length(x0) != 1) stop2(nm, " must be scalar.")
  if (x0 %in% c("true","t","1","yes","y","on")) return(TRUE)
  if (x0 %in% c("false","f","0","no","n","off","")) return(FALSE)
  stop2("Unrecognized boolean for ", nm, ": ", x)
}

parse_gene_list <- function(gene, genes, genes_file) {
  out <- character(0)
  if (nzchar(gene)) out <- c(out, str_trim(gene))
  if (nzchar(genes)) {
    parts <- str_trim(unlist(strsplit(genes, ",", fixed = TRUE)))
    parts <- parts[parts != ""]
    out <- c(out, parts)
  }
  if (nzchar(genes_file)) {
    if (!file.exists(genes_file)) stop2("genes_file not found: ", genes_file)
    lines <- str_trim(readLines(genes_file, warn = FALSE))
    lines <- lines[lines != ""]
    out <- c(out, lines)
  }
  out <- unique(out)
  out <- out[!is.na(out) & out != ""]
  out
}

parse_ordered_levels <- function(x) {
  if (!nzchar(x)) return(NULL)
  lev <- str_trim(unlist(strsplit(x, ",", fixed = TRUE)))
  lev <- lev[lev != ""]
  if (length(lev) < 2) stop2("--ordered_levels needs >=2 levels, e.g. 'Normal,PanIN,Cancer'")
  lev
}

# ----------------------------
# CLI
# ----------------------------
option_list <- list(
  make_option(c("--gse"), type="character", help="GSE accession, e.g. GSE13601"),
  make_option(c("--expr"), type="character", default="", help="Override expression path"),
  make_option(c("--meta"), type="character", default="", help="Override merged metadata path"),
  make_option(c("--group_col"), type="character", default="group_label",
              help="Column in merged meta to group by (default: group_label)"),
  
  # gene selection
  make_option(c("--gene"), type="character", default="", help="Single gene id (exact match)"),
  make_option(c("--genes"), type="character", default="", help="Comma-separated gene list"),
  make_option(c("--genes_file"), type="character", default="", help="Text file: one gene per line"),
  
  # main plot
  make_option(c("--plot_style"), type="character", default="violin",
              help="Main plot style: 'violin' or 'box'"),
  
  # FLOW-2: trend toggle + ordered levels
  make_option(c("--enable_trend"), type="character", default="FALSE",
              help="TRUE/FALSE. If TRUE, also generate ordered trend plot + trend stats."),
  make_option(c("--ordered_levels"), type="character", default="",
              help="Comma-separated ordered group levels, e.g. 'Normal,PanIN,Cancer'"),
  
  # unlabeled handling
  make_option(c("--drop_unlabeled"), type="character", default="TRUE",
              help="TRUE/FALSE. If TRUE, drop samples with group == 'NA' or empty before plotting main plot."),
  
  # output controls
  make_option(c("--module_id"), type="character", default="targeted_gene_distribution"),
  make_option(c("--dpi"), type="integer", default=300),
  make_option(c("--width"), type="double", default=7),
  make_option(c("--height"), type="double", default=5),
  
  # resolve behavior
  make_option(c("--suggest_n"), type="integer", default=20),
  make_option(c("--strict"), action="store_true", default=FALSE,
              help="If TRUE: stop on first missing gene. If FALSE: skip missing genes but report.")
)

opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$gse) || opt$gse == "") stop2("Missing --gse")
gse <- opt$gse

plot_style <- tolower(str_trim(opt$plot_style))
if (!plot_style %in% c("violin","box")) stop2("--plot_style must be 'violin' or 'box'.")

enable_trend <- parse_bool_tf(opt$enable_trend, nm="enable_trend")
drop_unlabeled <- parse_bool_tf(opt$drop_unlabeled, nm="drop_unlabeled")

ordered_levels <- parse_ordered_levels(opt$ordered_levels)
if (isTRUE(enable_trend) && is.null(ordered_levels)) {
  stop2("enable_trend=TRUE requires --ordered_levels, e.g. --ordered_levels 'Normal,PanIN,Cancer'")
}

genes <- parse_gene_list(opt$gene, opt$genes, opt$genes_file)
if (length(genes) == 0) stop2("No genes provided. Use --gene / --genes / --genes_file.")

expr_f <- file.path("data_processed", gse, "expression_gene_log.tsv")
meta_f <- file.path("data_processed", gse, "sample_metadata_merged.tsv")
if (nzchar(opt$expr)) expr_f <- opt$expr
if (nzchar(opt$meta)) meta_f <- opt$meta

# ----------------------------
# validate + aligned objects
# ----------------------------
v <- validate_v1_inputs(expr_f, meta_f, two_group_required = FALSE)
expr_mat <- v$expr_mat_included
meta_inc <- v$meta_included_aligned
if (is.null(expr_mat) || is.null(meta_inc)) stop2("Validator did not return aligned objects.")

if (!(opt$group_col %in% names(meta_inc))) stop2("--group_col not found in merged meta: ", opt$group_col)

# ----------------------------
# resolve gene ids
# ----------------------------
res <- resolve_gene_ids(expr_mat, genes, mode = "exact", suggest_n = opt$suggest_n)
resolved <- res$resolved
missing  <- res$missing

if (length(missing) > 0) {
  msg <- c("Some genes were not found in expr_mat:", paste0("  - ", missing))
  for (q in missing) {
    sug <- res$suggestions[[q]]
    if (!is.null(sug) && length(sug) > 0) msg <- c(msg, paste0("    suggestions: ", paste(sug, collapse=", ")))
  }
  if (isTRUE(opt$strict)) stop2(paste(msg, collapse="\n"))
  message(paste(msg, collapse="\n"))
}
if (length(resolved) == 0) stop2("No genes resolved. Check gene_id naming in expression_gene_log.tsv.")

# ----------------------------
# run per gene
# ----------------------------
module_id <- opt$module_id
base_res_dir <- file.path("results", gse, module_id)
dir.create(base_res_dir, recursive = TRUE, showWarnings = FALSE)

ok_genes <- character(0)
skipped_genes <- character(0)

for (gene_id in resolved) {
  gene_dir <- file.path(base_res_dir, gene_id)
  dir.create(gene_dir, recursive = TRUE, showWarnings = FALSE)
  
  df_long <- make_gene_long_df(
    expr_mat = expr_mat,
    meta_inc = meta_inc,
    gene_id = gene_id,
    group_col = opt$group_col
  )
  
  # optionally drop unlabeled for MAIN plot only
  df_main <- df_long
  if (isTRUE(drop_unlabeled)) {
    df_main <- df_main %>%
      mutate(group_chr = as.character(group)) %>%
      filter(!is.na(group_chr), str_trim(group_chr) != "", group_chr != "NA") %>%
      select(-group_chr)
    df_main$group <- droplevels(df_main$group)
  }
  
  # decide ordered_levels to pass (trend off => NULL)
  ol <- if (isTRUE(enable_trend)) ordered_levels else NULL
  
  out <- write_gene_outputs(
    out_dir = gene_dir,
    gse = gse,
    gene_id = gene_id,
    df_long = df_main,                 # main plot/stats use df_main
    group_col_used = opt$group_col,
    plot_style = plot_style,
    ordered_levels = ol,               # trend only if enabled
    dpi = opt$dpi,
    width = opt$width,
    height = opt$height
  )
  
  manifest_path <- file.path(gene_dir, "manifest.json")
  write_manifest_json(
    manifest_path = manifest_path,
    module_id = module_id,
    gse = gse,
    inputs = list(expr = expr_f, meta = meta_f),
    outputs = out$paths,
    args = list(
      group_col = opt$group_col,
      gene = gene_id,
      plot_style = plot_style,
      drop_unlabeled = drop_unlabeled,
      enable_trend = enable_trend,
      ordered_levels = if (isTRUE(enable_trend)) opt$ordered_levels else "",
      dpi = opt$dpi,
      width = opt$width,
      height = opt$height
    ),
    extra = list(
      gene_id = gene_id,
      n_samples_included = ncol(expr_mat),
      group_levels_main = levels(factor(df_main$group)),
      trend_levels = if (isTRUE(enable_trend)) ordered_levels else character(0)
    )
  )
  
  message("DONE gene: ", gene_id, " | main: ", out$paths$main_plot_png)
  if (isTRUE(enable_trend) && !is.null(out$paths$trend_plot_png) && nzchar(out$paths$trend_plot_png)) {
    message("  + trend: ", out$paths$trend_plot_png)
  }
  
  ok_genes <- c(ok_genes, gene_id)
}

# ----------------------------
# module runlog
# ----------------------------
summary_log <- file.path(base_res_dir, "runlog.txt")
writeLines(c(
  paste0("GSE: ", gse),
  paste0("expr: ", expr_f),
  paste0("meta: ", meta_f),
  paste0("module_id: ", module_id),
  paste0("group_col: ", opt$group_col),
  paste0("plot_style: ", plot_style),
  paste0("drop_unlabeled: ", drop_unlabeled),
  paste0("enable_trend: ", enable_trend),
  paste0("ordered_levels: ", if (isTRUE(enable_trend)) paste(ordered_levels, collapse="→") else ""),
  paste0("genes_requested: ", paste(genes, collapse=", ")),
  paste0("genes_resolved: ", paste(resolved, collapse=", ")),
  paste0("genes_missing: ", if (length(missing) == 0) "" else paste(missing, collapse=", ")),
  paste0("genes_ok: ", paste(ok_genes, collapse=", "))
), con = summary_log)

message("Saved module runlog: ", summary_log)
message("Done.")
